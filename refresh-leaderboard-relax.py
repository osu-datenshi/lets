import json
import os
import shutil
import sys
from distutils.version import LooseVersion
from multiprocessing.pool import ThreadPool

import redis

import secret.achievements.utils
from common import generalUtils
from common.constants import bcolors
from common.db import dbConnector
from common.ripple.userUtils import refreshStatsRx, getAll
from constants import rankedStatuses
from helpers import config
from helpers import consoleHelper
from objects import glob


def init():
    consoleHelper.printServerStartHeader(True)

    # Read config
    consoleHelper.printNoNl("> Reading config file... ")
    glob.conf = config.config("config.ini")

    if glob.conf.default:
        # We have generated a default config.ini, quit server
        consoleHelper.printWarning()
        consoleHelper.printColored("[!] config.ini not found. A default one has been generated.", bcolors.YELLOW)
        consoleHelper.printColored("[!] Please edit your config.ini and run the server again.", bcolors.YELLOW)
        sys.exit()

    # If we haven't generated a default config.ini, check if it's valid
    if not glob.conf.checkConfig():
        consoleHelper.printError()
        consoleHelper.printColored("[!] Invalid config.ini. Please configure it properly", bcolors.RED)
        consoleHelper.printColored("[!] Delete your config.ini to generate a default one", bcolors.RED)
        sys.exit()
    else:
        consoleHelper.printDone()

    # Read additional config file
    consoleHelper.printNoNl("> Loading additional config file... ")
    try:
        if not os.path.isfile(glob.conf.config["custom"]["config"]):
            consoleHelper.printWarning()
            consoleHelper.printColored(
                "[!] Missing config file at {}; A default one has been generated at this location.".format(
                    glob.conf.config["custom"]["config"]), bcolors.YELLOW)
            shutil.copy("common/default_config.json", glob.conf.config["custom"]["config"])

        with open(glob.conf.config["custom"]["config"], "r") as f:
            glob.conf.extra = json.load(f)

        consoleHelper.printDone()
    except:
        consoleHelper.printWarning()
        consoleHelper.printColored(
            "[!] Unable to load custom config at {}".format(glob.conf.config["custom"]["config"]), bcolors.RED)
        consoleHelper.printColored("[!] Make sure you have the latest osu!thailand common submodule!", bcolors.RED)
        sys.exit()

    # Check if running common module is usable
    if glob.COMMON_VERSION == "Unknown":
        consoleHelper.printWarning()
        consoleHelper.printColored(
            "[!] You do not seem to be using osu!thailand's common submodule... nothing will work...", bcolors.RED)
        consoleHelper.printColored(
            "[!] You can download or fork the submodule from {}https://github.com/osuthailand/common".format(
                bcolors.UNDERLINE), bcolors.RED)
        sys.exit()
    elif LooseVersion(glob.COMMON_VERSION_REQ) > LooseVersion(glob.COMMON_VERSION):
        consoleHelper.printColored(
            "[!] Your common submodule version is below the required version number for this version of lets.",
            bcolors.RED)
        consoleHelper.printColored(
            "[!] You are highly adviced to update your common submodule as stability may vary with outdated modules.",
            bcolors.RED)

    # Create data/oppai maps folder if needed
    consoleHelper.printNoNl("> Checking folders... ")
    paths = [
        ".data",
        ".data/oppai",
        ".data/catch_the_pp",
        glob.conf.config["server"]["replayspath"],
        "{}_relax".format(glob.conf.config["server"]["replayspath"]),
        glob.conf.config["server"]["beatmapspath"],
        glob.conf.config["server"]["screenshotspath"]
    ]
    for i in paths:
        if not os.path.exists(i):
            os.makedirs(i, 0o770)
    consoleHelper.printDone()

    # Connect to db
    try:
        consoleHelper.printNoNl("> Connecting to MySQL database... ")
        glob.db = dbConnector.db(glob.conf.config["db"]["host"], glob.conf.config["db"]["username"],
                                 glob.conf.config["db"]["password"], glob.conf.config["db"]["database"], int(
                glob.conf.config["db"]["workers"]))
        consoleHelper.printNoNl(" ")
        consoleHelper.printDone()
    except:
        # Exception while connecting to db
        consoleHelper.printError()
        consoleHelper.printColored(
            "[!] Error while connection to database. Please check your config.ini and run the server again",
            bcolors.RED)
        raise

    # Connect to redis
    try:
        consoleHelper.printNoNl("> Connecting to redis... ")
        glob.redis = redis.Redis(glob.conf.config["redis"]["host"], glob.conf.config["redis"]["port"],
                                 glob.conf.config["redis"]["database"], glob.conf.config["redis"]["password"])
        glob.redis.ping()
        consoleHelper.printNoNl(" ")
        consoleHelper.printDone()
    except:
        # Exception while connecting to db
        consoleHelper.printError()
        consoleHelper.printColored(
            "[!] Error while connection to redis. Please check your config.ini and run the server again", bcolors.RED)
        raise

    # Empty redis cache
    try:
        glob.redis.eval("return redis.call('del', unpack(redis.call('keys', ARGV[1])))", 0, "lets:*")
    except redis.exceptions.ResponseError:
        # Script returns error if there are no keys starting with peppy:*
        pass

    # Save lets version in redis
    glob.redis.set("lets:version", glob.VERSION)

    # Create threads pool
    try:
        consoleHelper.printNoNl("> Creating threads pool... ")
        glob.pool = ThreadPool(int(glob.conf.config["server"]["threads"]))
        consoleHelper.printDone()
    except:
        consoleHelper.printError()
        consoleHelper.printColored(
            "[!] Error while creating threads pool. Please check your config.ini and run the server again", bcolors.RED)

    # Check osuapi
    if not generalUtils.stringToBool(glob.conf.config["osuapi"]["enable"]):
        consoleHelper.printColored(
            "[!] osu!api features are disabled. If you don't have a valid beatmaps table, all beatmaps will show as "
            "unranked",
            bcolors.YELLOW)
        if int(glob.conf.config["server"]["beatmapcacheexpire"]) > 0:
            consoleHelper.printColored(
                "[!] IMPORTANT! Your beatmapcacheexpire in config.ini is > 0 and osu!api features are disabled.\nWe "
                "do not reccoment this, because too old beatmaps will be shown as unranked.\nSet beatmapcacheexpire "
                "to 0 to disable beatmap latest update check and fix that issue.",
                bcolors.YELLOW)

    # Load achievements
    consoleHelper.printNoNl("Loading achievements... ")
    try:
        secret.achievements.utils.load_achievements()
    except Exception as e:
        consoleHelper.printError()
        consoleHelper.printColored(
            "[!] Error while loading achievements! ({})".format(e),
            bcolors.RED,
        )
        sys.exit()
    consoleHelper.printDone()

    # Set achievements version
    glob.redis.set("lets:achievements_version", glob.ACHIEVEMENTS_VERSION)
    consoleHelper.printColored("Achievements version is {}".format(glob.ACHIEVEMENTS_VERSION), bcolors.YELLOW)

    # Print disallowed mods into console (Used to also assign it into variable but has been moved elsewhere)
    unranked_mods = [key for key, value in glob.conf.extra["common"]["rankable-mods"].items() if not value]
    consoleHelper.printColored("Unranked mods: {}".format(", ".join(unranked_mods)), bcolors.YELLOW)

    # Print allowed beatmap rank statuses
    allowed_beatmap_rank = [key for key, value in glob.conf.extra["lets"]["allowed-beatmap-rankstatus"].items() if
                            value]
    consoleHelper.printColored("Allowed beatmap rank statuses: {}".format(", ".join(allowed_beatmap_rank)),
                               bcolors.YELLOW)

    # Make array of bools to respective rank id's
    glob.conf.extra["_allowed_beatmap_rank"] = [getattr(rankedStatuses, key) for key in
                                                allowed_beatmap_rank]  # Store the allowed beatmap rank id's into glob

    # Check debug mods
    glob.debug = generalUtils.stringToBool(glob.conf.config["server"]["debug"])
    if glob.debug:
        consoleHelper.printColored("[!] Warning! Server running in debug mode!", bcolors.YELLOW)


if __name__ == '__main__':
    init()

    users = getAll()
    for user in users:
        refreshStatsRx(user['id'], 0)  # 0 is std
