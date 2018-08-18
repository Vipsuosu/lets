import tornado.gen
import tornado.web
import requests

from common.web import requestsManager
from constants import exceptions
from common.sentry import sentry
from helpers import levbodHelper

MODULE_NAME = "direct"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-search.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):
		output = ""
		try:
			username = self.get_argument("u")
			password = self.get_argument("h")
			response = requests.get("https://new.vipsu.ml/api/v1/users/favs?u={0}&h={1}".format(username,password))
			output += response.text
		finally:
			self.write(output)