def ping()
    # PING
	try:
		glob.db.execute("SELECT 1+1")
        consoleHelper.printColored("the command has been execute!", bcolors.GREEN)
	except:
		consoleHelper.printColored("command not working", bcolors.RED)