import requests
import json

import tornado.gen
import tornado.web

#from common.log import logUtils as log
from common.web import requestsManager
from common.sentry import sentry
from objects import glob

MODULE_NAME = "direct_download"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /d/
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self, bid):
		try:
			noVideo = bid.endswith("n")
			if noVideo:
				bid = bid[:-1]
			bid = int(bid)

			self.set_status(302, "Moved Temporarily")
			#URL CAN BE CHANGED TO ANYTHING
			#SUCH AS https://akatsuki.pw/d/
			url = "https://storage.ainu.pw/d/{}{}".format(bid, "?novideo" if noVideo else "")
			self.add_header("Location", url)
			self.add_header("Cache-Control", "no-cache")
			self.add_header("Pragma", "no-cache")
			#log.info("USING pisstau.be FOR BEATMAPS")
		except ValueError:
			self.set_status(400)
			self.write("Invalid set id")
