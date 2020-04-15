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
		if glob.conf.config["beatconnect"]["enable"] == True:
			try:
				noVideo = bid.endswith("n")
				if noVideo:
					bid = bid[:-1]
				bid = int(bid)

				self.set_status(200, "OK")
				beatmap = requests.get("https://beatconnect.io/api/beatmap/{}/?token={}".format(bid, glob.conf.config["beatconnect"]["apikey"])).text
				uniqueid = json.loads(beatmap)['unique_id']
				url = "https://beatconnect.io/b/{}/{}{}".format(bid, uniqueid, "?novideo=1" if noVideo else "")
				response = requests.get(url)
				self.add_header("Content-Type", "application/octet-stream")
				self.add_header("Content-Length", response.headers['Content-Length'])
				self.add_header("Content-Disposition", response.headers['Content-Disposition'])
				self.add_header("Cache-Control", "no-cache")
				self.add_header("Pragma", "no-cache")
				self.write(response.content)
				#log.info("USING beatconnect.io FOR BEATMAPS")
			except ValueError:
				self.set_status(400)
				self.write("Invalid set id")
		else:
			try:
				noVideo = bid.endswith("n")
				if noVideo:
					bid = bid[:-1]
				bid = int(bid)

				self.set_status(302, "Moved Temporarily")
				#URL CAN BE CHANGED TO ANYTHING
				#SUCH AS https://akatsuki.pw/d/
				url = "https://pisstau.be/d/{}{}".format(bid, "?novideo" if noVideo else "")
				self.add_header("Location", url)
				self.add_header("Cache-Control", "no-cache")
				self.add_header("Pragma", "no-cache")
				#log.info("USING pisstau.be FOR BEATMAPS")
			except ValueError:
				self.set_status(400)
				self.write("Invalid set id")
