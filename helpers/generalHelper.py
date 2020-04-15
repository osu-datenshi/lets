import datetime

def zingonify(d):
    """
    Zingonifies a string

    :param d: input dict
    :return: zingonified dict as str
    """
    return "|".join(f"{k}:{v}" for k, v in d.items())

def clamp(x, min_, max_):
    return max(min(x, max_), min_)

def toDotTicks(unixTime):
    '''
    Thanks to osukurikku's LETS
    Commit ID: 0a8236463242ea56ddb93c1f7823a5e39cd69911

    :param unixTime: unixTimeStamp
    '''
    unixStamp = datetime.datetime.fromtimestamp(unixTime)
    base = datetime.datetime(1, 1, 1, 0, 0, 0)
    delt = unixStamp-base
    return int(delt.total_seconds())*10000000

def setUserSession(userID: int, sessionObj: dict):
    '''
    Thanks to osukurikku's LETS
    Commit ID: cad58ed96f52847c8b89b066586b9f3a8c4d4920
    '''
    glob.db.execute("UPDATE users SET last_session = %s WHERE userID = %s", [
    json.dumps(sessionObj), userID])
    return True

cheat_ids = {
    1: 'ReLife|HqOsu is running',
    2: 'Console in BG is found',
    4: 'Wrong mod combination',
    8: 'Invalid name?',
    13: 'ReLife|HqOsu has loaded',
    16: 'Invalid file?',
    32: 'ReLife|HqOsu has loaded',
    64: 'AqnSdl2Loaded (lib for overlay)',
    128: 'AqnLibeay32Loaded (lib for SSL)'
}

def getHackByFlag(flag):
    if cheat_ids.get(flag, False):
        return cheat_ids[flag]
    else:
        return flag