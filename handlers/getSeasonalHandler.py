from urllib.parse import urlencode

import requests
import tornado.gen
import tornado.web

from common.log import logUtils as log
from common.web import requestsManager


class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	def asyncGet(self):
		try:
			response = requests.get("https://old.troke.id/seasonal.php")
			self.write(response.text)
		except Exception as e:
			log.error("check-seasonal failed: {}".format(e))
			self.write("")
