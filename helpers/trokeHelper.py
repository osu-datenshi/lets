import schedule
import time

def ping():
	# PING
	try:
		glob.db.execute("SELECT 1+1")
		print("ok")
	except:
		print("not ok")

schedule.every(10).seconds.do(ping)

while True:
		schedule.run_pending()
		time.sleep(1)
		print("ok")