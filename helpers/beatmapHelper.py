import time
import datetime
import requests
from urllib.parse import urlencode

from common.log import logUtils as log
from common.datenshi import rankUtils
from common.ripple import userUtils
from constants import rankedStatuses
from helpers import osuapiHelper
from objects import glob
from discord_webhook import DiscordWebhook, DiscordEmbed

QUALIFIED_DAYS = 3
GRAVEYARD_DAYS = 28

def _wrapper_():
    """
    Beatmap Helper Wrapper
    
    To get short explanation, this will have two parts.
    - Criteria system, which degrades or checks map automatically.
    - Autorank system, which promotes map automatically.
    """
    """ CRITERIA SYSTEM """
    def getAllCriteria():
        return glob.db.fetchAll('select * from beatmaps_criteria_control where active = 1 order by priority desc, criteria_id asc');
    def getMatchingCriteria(beatmap):
        criteriaIDs = []
        mapKey = {
            'beatmapset_id': 'beatmapSetID',
            'beatmap_id': 'beatmapID',
            'creator_id': 'creatorID',
            'ranked': 'rankedStatus'
        }
        for criteria in getAllCriteria():
            # SANITY CHECK: inactive criteria get out
            if not criteria['active']:
                continue
            # SKIP IF ALL CRITERIA IS NULL
            checkable = dict((k, criteria[k]) for k in mapKey if criteria[k] is not None)
            if not checkable:
                continue
            # CHECK ALL CRITERIONS HERE
            if not all(checkable[k] == getattr(beatmap,mapKey[k]) for k in mapKey if k in checkable):
                continue
            criteriaIDs.append(criteria['criteria_id'])
            if criteria['stop_on_hit']:
                break
        return criteriaIDs
    def getCriteriaAction(criteriaID):
        return glob.db.fetchAll('select type, int_value as iv, str_value as sv from beatmaps_criteria_actions where criteria_id = %s',[criteriaID])
    
    def criteria__0001RankStatus(beatmap,iv,sv):
        if beatmap.rankedStatusFrozen:
            return
        if beatmap.rankedStatus == iv:
            return
        beatmap.rankedStatus = iv
    def criteria__0002RankFreeze(beatmap,iv,sv):
        if beatmap.rankedStatusFrozen == iv:
            return
        if bool(beatmap.rankedStatusFrozen) == bool(iv):
            return
        beatmap.rankedStatusFrozen = iv
    def criteria__0003MapDisplay(beatmap,iv,sv):
        if beatmap.displayTitle == sv:
            return
        beatmap.displayTitle = sv
    criteriaActions = {}
    # Nene超進化! Super Hyper Ultra Ultimate Deluxe Perfect Amazing Shining God 流派東方不敗 Master Freedom Justice Ginga Victory Prime Strong Cute Beautiful Wonderful Champion Galaxy Baby 最高 勇者王 天元突破 無限 無敵 無双 NENEMAXMAXMAXSTORONG NENECHI!
    criteriaActions[0] = lambda bm, iv, sv: None
    criteriaActions[1] = criteria__0001RankStatus
    criteriaActions[2] = criteria__0002RankFreeze
    criteriaActions[3] = criteria__0003MapDisplay
    def criteriaControl(beatmap):
        """
        Criteria Control
          Checks if the beatmap have matching criteria.
          If any, get all available actions.
          For each registered action type, perform it sequential.
          
          NOTE: Custom Beatmaps ARE EXEMPT from criteria control system.
        """
        for cid in getMatchingCriteria(beatmap):
            for act in getCriteriaAction(cid):
                if act['type'] in criteriaActions:
                    criteriaActions[act['type']](beatmap,act['iv'],act['sv'])
    
    """ AUTORANK SYSTEM """
    def autorankQueryWrapper(field, table, key, value):
        r = glob.db.fetch("SELECT {field} as f FROM {table} WHERE {key} = %s".format(field=field,table=table,key=key),[value])
        if r is None:
            return False
        return bool(r['f'])
    def autorankActive(banchoID):
        return autorankQueryWrapper('active','autorank_users','bancho_id', banchoID)
    def autorankUserID(banchoID):
        r = glob.db.fetch("SELECT datenshi_id as user_id FROM autorank_users WHERE bancho_id = %s",[banchoID])
        if r is None:
            return None
        return r['user_id']
    def autorankFlagOK(beatmapID):
        return autorankQueryWrapper('flag_valid','autorank_flags','beatmap_id', beatmapID)
    def autorankFlagForLove(beatmapID):
        return autorankQueryWrapper('flag_lovable','autorank_flags','beatmap_id', beatmapID)
    def autorankAnnounce(beatmap):
        if beatmap.rankedStatus >= 0:
            status = 'disqualified update ranked approved qualified loved'.split()[beatmap.rankedStatus]
        else:
            status = 'void'
        mapData = {
            'artist': beatmap.artist,
            'title': beatmap.title,
            'difficulty_name': beatmap.difficultyName,
            'beatmapset_id': beatmap.beatmapSetID,
            'beatmap_id': beatmap.beatmapID,
            'rankedby': str(autorankUserID(beatmap.creatorID))
        }
        def banchoCallback(msg):
            for c in '#announce #ranked-now'.split():
                params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": c, "msg": msg})
                requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
        rankUtils.announceMapRaw(mapData, status, autoFlag=True, banchoCallback=banchoCallback)
    def autorankCheck(beatmap):
        # No autorank check for frozen maps
        if beatmap.rankedStatusFrozen not in (0,3):
            return
        # No autorank check for already ranked beatmap
        # Only handle this if the map is ranked by autorank.
        if beatmap.rankedStatusFrozen != 3 and beatmap.rankedStatus >= 2:
            return
        # Only check if the mapper flag is active
        if not autorankActive(beatmap.creatorID):
            return
        # Only check if the map is autorankable.
        if not autorankFlagOK(beatmap.beatmapID):
            return
        # Not checking maps with non updated date.
        log.info(f"Checking {beatmap.songName} for autorank eligiblity.")
        obtainDateTime  = lambda t: datetime.datetime.strptime(t, "%Y-%m-%d %H:%M:%S")
        obtainUnixClock = lambda t: int(time.mktime(t.timetuple()))
        if beatmap.updateDate == 0:
            log.info(f"Updating {beatmap.fileMD5} data")
            data = osuapiHelper.osuApiRequest('get_beatmaps','h={}'.format(beatmap.fileMD5))
            if not data:
                return
            dateTouch   = obtainDateTime(data['last_update'])
            beatmap.updateDate = obtainUnixClock(dateTouch)
        else:
            dateTouch   = datetime.datetime.fromtimestamp(beatmap.updateDate)
        
        dateNow     = datetime.datetime.today()
        dateQualify = dateTouch + datetime.timedelta(days=GRAVEYARD_DAYS - QUALIFIED_DAYS)
        dateRanked  = dateTouch + datetime.timedelta(days=GRAVEYARD_DAYS)
        forLove     = autorankFlagForLove(beatmap.beatmapID)
        rankStatus  = beatmap.rankedStatus
        needWipe    = False
        if dateNow >= dateRanked:
            needWipe = rankStatus == rankedStatuses.QUALIFIED
            if forLove:
                log.debug(f"Considering {beatmap.fileMD5} to be loved")
                beatmap.rankedStatus = rankedStatuses.LOVED
            else:
                log.debug(f"Considering {beatmap.fileMD5} on ranking")
                beatmap.rankedStatus = rankedStatuses.RANKED
            beatmap.rankedStatusFrozen = 3
        elif dateNow >= dateQualify and not forLove:
            log.debug(f"Considering {beatmap.fileMD5} for qualified")
            beatmap.rankedStatus = rankedStatuses.QUALIFIED
            beatmap.rankedStatusFrozen = 3
        else:
            needWipe = rankStatus >= rankedStatuses.RANKED
            beatmap.rankedStatus = rankedStatuses.PENDING
            beatmap.rankedStatusFrozen = 0
        if rankStatus != beatmap.rankedStatus:
            glob.db.execute('update beatmaps set ranked_status_freezed = 0 where beatmap_md5 = %s', [beatmap.fileMD5])
            autorankAnnounce(beatmap)
        if needWipe:
            log.info(f"Wiping {beatmap.fileMD5} leaderboard")
            beatmap.clearLeaderboard()
            pass
    
    whitelistFunList = [criteriaControl,autorankCheck]
    whitelistFun = {}
    for f in whitelistFunList:
        whitelistFun[f.__name__] = f
    globals().update(whitelistFun)

_wrapper_()
del _wrapper_
