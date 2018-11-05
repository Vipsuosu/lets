import os
import sys
import traceback
import string
import time

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from common import generalUtils
from objects import glob
from common.sentry import sentry

MODULE_NAME = "bmsubmitGetid"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-get-beatmap-topic.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):
		try:
			requestsManager.printArguments(self)

			# Check user auth because of sneaky people
			if not requestsManager.checkArguments(self.request.arguments, ["u", "h"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)
			username = self.get_argument("u")
			password = self.get_argument("h")
			userID = userUtils.getID(username)
			if not userUtils.checkLogin(userID, password):
				raise exceptions.loginFailedException(MODULE_NAME, username)

			beatmapSetId = int(self.get_argument("s"))
			beatmapIds = self.get_argument("b").split(',')
			oldOsz2Hash  = self.get_argument("z")

			if userID != 1000:
				return self.write(return_errorcode(5, "fuck you, you are NOT Peppy"))
			glob.db.execute("DELETE FROM gatari_beatmapsets WHERE user_id = {} AND active = -1".format(userID))
			bmInfo = fetch_info(beatmapSetId,False)
			if beatmapSetId > 0 and bmInfo is not None:
				if authenticate_creator(userID,bmInfo["user_id"],username) == False:
					return self.write(return_errorcode(1, ""))
				if(bmInfo["ranked"] > 0 and has_special_permissions(username) == False):
					return self.write(return_errorcode(3, ""))
			else:
				uploadcap = check_remaining_uploadcap(userID)
				if(uploadcap == 0):
					return self.write(return_errorcode(6, "You have exceeded your submission cap"))
				if(uploadcap == -1):
					return self.write(return_errorcode(6, "Only druzhbans can submit beatmaps"))
				beatmapSetId = create_beatmapset(userID, username)
				newSubmit = True

			serverHash = get_osz2_file_hash(beatmapSetId)
			fullSubmit = newSubmit or oldOsz2Hash == "0" or serverHash is None or serverHash != oldOsz2Hash
			self.write("0\n\
				{}\n\
				{}\n\
				{}\n\
				{}\n\
				0\n\
				{}".format(beatmapSetId, self.get_argument("b"), "1" if fullSubmit == True else "2", int(uploadcap),0))

		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			pass

def return_errorcode(code,message):
	return "{}\n{}".format(code,message)

def get_osz2_file_hash(beatmapSetId):
	return glob.db.fetch("SELECT lcase(hex(osz2_hash)) FROM gatari_beatmapsets WHERE beatmapset_id = %s",[beatmapSetId])

def fetch_info(beatmapSetId, allowInactive = False):
	return glob.db.fetch("SELECT user_id, ranked, body_hash FROM gatari_beatmapsets WHERE beatmapset_id = %s "+"AND active > 0" if allowInactive == False else "",[beatmapSetId])

def authenticate_creator(userID, creatorID, username):
	if has_special_permissions(username) == True:
		return True
	return userID == creatorID

def has_special_permissions(username):
	return username == "peppynator"

def check_remaining_uploadcap(userID):
	unrankedCount = glob.db.fetch("SELECT count(*) count from gatari_beatmapsets where ranked in (-1,0) and active > 0 and user_id = %s",[userID])["count"]
	rankedCount =  glob.db.fetch("SELECT count(*) count from gatari_beatmapsets where ranked > 0 and active > 0 and user_id = %s",[userID])["count"]
	druzban = int(glob.db.fetch("SELECT count(*) count FROM users WHERE id=%s AND privileges & 4 > 0",[userID])["count"])
	if druzban < 1:
		return -1
	mapAllowance = 3 + min(3, rankedCount)
	return mapAllowance - unrankedCount

def create_beatmapset(userID, username):
	return int(glob.db.execute("INSERT INTO gatari_beatmapsets (user_id, creator, ranked, active, submit_date, latest_update) VALUES (%s, %s, 0, -1, %s, %s)",[userID, username, int(time.time()), int(time.time())]))
	