import tornado.gen
import tornado.web

from common.ripple import userUtils
from common.web import requestsManager
from secret.discord_hooks import Webhook
from objects import glob
from helpers import generalHelper

MODULE_NAME = "lastFMHandler"
class handler(requestsManager.asyncRequestHandler):
    """
    Handler for /web/lastfm.php

    Handler by @KotRikD
    Enum values by @Enjuu and @Cyuubi
    """
    @tornado.web.asynchronous
    @tornado.gen.engine
    def asyncGet(self):
        if glob.conf.config["discord"]["enable"] == True:
            webhook = Webhook(glob.conf.config["discord"]["ahook"],
                      color=0xadd8e6,
                      footer="Man... this is worst player. [ LastFM AC ]")

        ip = self.getRequestIP()
        if not requestsManager.checkArguments(self.request.arguments, ["b", "ha", "us"]):
            return self.write("error: gimme more arguments")

        username = self.get_argument("us")
        password = self.get_argument("ha")
        beatmap_ban = self.get_argument("b", None)

        userID = userUtils.getID(username)
        if userID == 0:
            return self.write("error: user is unknown")
        if not userUtils.checkLogin(userID, password, ip):
            return self.write("error: this dude is not authorized. BAN!")
        if not beatmap_ban or beatmap_ban and not beatmap_ban.startswith("a"):
            return self.write("-3")

        arguments_cheat = beatmap_ban[1:]
        if not arguments_cheat.isdigit():
            return self.write("error: srsly?")

        arguments_cheat = int(arguments_cheat)
        # Let's try found something
        cheat_id = generalHelper.getHackByFlag(arguments_cheat)
        if glob.conf.config["discord"]["enable"] == True:
            webhook.set_title(title=f"Catched some cheater {username} ({userID})")
            if type(cheat_id) == str:
                webhook.set_desc(f'This body catched with flag {arguments_cheat}\nIn enuming: {cheat_id}')
            else:
                webhook.set_desc(f'This body catched with undefined flag {arguments_cheat}')

            if glob.conf.extra["mode"]["anticheat"] == True:
                webhook.post()

        return self.write("-3")
