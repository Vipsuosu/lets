import tornado.gen
import tornado.web
import requests

from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from common.sentry import sentry
from helpers import levbodHelper
from common.log import logUtils as log
from objects import glob
class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado

	def asyncGet(self):
		output = ""
		try:
			username = self.get_argument("u","")
			password = self.get_argument("p","")
			vote = self.get_argument("v", "")
			beatmapMD5 = self.get_argument("c")
			userID = userUtils.getID(username)
			if not userUtils.checkLogin(userID, password):
				self.write("auth fail")
				return
			beatmap = glob.db.fetch("SELECT ranked, rating FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1",[beatmapMD5])
			if beatmap is not None:
				if int(beatmap['ranked']) < 1:
					self.write('not ranked')
					return
				alreadyVoted = glob.db.fetch("SELECT rating FROM user_beatmaps_rating WHERE userid = %s AND beatmap_md5 = %s ",[userID, beatmapMD5])
				if alreadyVoted is not None:
					currentRating = round(beatmap["rating"],2)
					self.write("alreadyvoted\n{}".format(currentRating))
					return
			else:
				self.write('not ranked')
				return
			if str(vote).isdigit() == False:
				output = 'ok'
			else:
				vote = int(vote)
				if vote > 10 or vote < 0:
					output = 'out of range'
				else:
					glob.db.execute('INSERT INTO user_beatmaps_rating (userid, beatmap_md5, rating) VALUE(%s, %s, %s)',[userID, beatmapMD5, vote])
					glob.db.execute('UPDATE beatmaps SET rating = (SELECT sum(rating) / count(rating) FROM `user_beatmaps_rating` WHERE beatmap_md5 = %(md5)s) WHERE beatmap_md5 = %(md5)s',{'md5':beatmapMD5})
					rating = glob.db.fetch("SELECT rating FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1",[beatmapMD5])['rating']
					output = str(round(rating,2))
		finally:
			self.write(output)
