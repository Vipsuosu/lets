import time
import requests
import datetime
import re

from common.log import logUtils as log
from constants import rankedStatuses
from helpers import osuapiHelper
from objects import glob


class beatmap:
	def __init__(self, md5 = None, beatmapSetID = None, gameMode = 0, refresh=False, fileName=""):
		"""
		Initialize a beatmap object.

		md5 -- beatmap md5. Optional.
		beatmapSetID -- beatmapSetID. Optional.
		"""
		self.songName = ""
		self.artist = ""
		self.title = ""
		self.version = ""
		self.creator = ""
		self.fileMD5 = ""
		self.rankedStatus = rankedStatuses.NOT_SUBMITTED
		self.rankedStatusFrozen = 0
		self.beatmapID = 0
		self.beatmapSetID = 0
		self.offset = 0		# Won't implement
		self.rating = 10.0 	# Won't implement
		self.rankingDate = 0
		self.starsStd = 0.0	# stars for converted
		self.starsTaiko = 0.0	# stars for converted
		self.starsCtb = 0.0		# stars for converted
		self.starsMania = 0.0	# stars for converted
		self.AR = 0.0
		self.OD = 0.0
		self.HP = 0.0
		self.CS = 0.0
		self.mode = 0
		self.maxCombo = 0
		self.hitLength = 0
		self.bpm = 0

		# Statistics for ranking panel
		self.playcount = 0
		self.passcount = 0

		# Force refresh from osu api
		self.refresh = refresh

		if (fileName != ""):
			regex = r".* \[(.*)\]"
			prog = re.compile(regex)
			result = prog.match(fileName)
			if result is not None:
				self.version = result.group(1)

		if md5 is not None and beatmapSetID is not None:
			self.setData(md5, beatmapSetID)

	def addBeatmapToDB(self):
		"""
		Add current beatmap data in db if not in yet
		"""
		# Make sure the beatmap is not already in db
		if self.fileMD5 is None:
			self.rankedStatus = rankedStatuses.NOT_SUBMITTED
			return 
		bdata = glob.db.fetch("SELECT id, ranked_status_freezed, ranked FROM beatmaps WHERE beatmap_md5 LIKE %s LIMIT 1", [self.fileMD5])
		if bdata is not None:
			# This beatmap is already in db, remove old record
			# Get current frozen status
			frozen = bdata["ranked_status_freezed"]
			if frozen > 0:
				self.rankedStatus = bdata["ranked"]
			log.debug("Deleting old beatmap data ({})".format(bdata["id"]))
		
			#glob.db.execute("DELETE FROM beatmaps WHERE id = %s LIMIT 1", [bdata["id"]])
			if frozen == 0 and self.rankedStatus > 2:
				if(self.rankedStatus == 2 and bdata["ranked"] == 4):
					log.warning("rankedstatus 2 bdata = 4 {}".format(self.fileMD5))
					glob.db.execute("DELETE FROM scores WHERE beatmap_md5 = %s",[self.fileMD5] )
				glob.db.execute("UPDATE `beatmaps` SET   `ranking_data` = %s WHERE beatmap_id = %s ", [
				self.rankingDate if self.rankedStatus > 0 else 0,
				self.beatmapID
				])

			glob.db.execute("UPDATE `beatmaps` SET  `latest_update` = %s, `artist` = %s,`title` = %s,`version` = %s, `creator` = %s ,`ranked_status_freezed` = %s, `ranked` = %s, `hp` = %s,`cs` = %s , `difficulty_std` = %s, `difficulty_taiko` = %s, `difficulty_ctb` = %s, `difficulty_mania` = %s, `max_combo` = %s  WHERE beatmap_id = %s ", [
			int(time.time()),
			self.artist.encode("utf-8", "ignore").decode("utf-8"),
			self.title.encode("utf-8", "ignore").decode("utf-8"),
			self.version.encode("utf-8", "ignore").decode("utf-8"),
			self.creator.encode("utf-8", "ignore").decode("utf-8"),
			frozen,
			self.rankedStatus,
			self.HP,
			self.CS,
			self.starsStd,
			self.starsTaiko,
			self.starsCtb,
			self.starsMania,
			self.maxCombo,
			self.beatmapID
			])
		
		else:
			# Unfreeze beatmap status
			log.warning("karti net v db md5={},id={} rank={}".format(self.fileMD5, self.beatmapID,self.rankedStatus))
			#glob.db.execute("DELETE FROM beatmaps WHERE beatmap_id = %s ",[self.beatmapID])
			frozen = 0
			try:
				glob.db.execute("INSERT INTO `beatmaps` (`id`, `beatmap_id`, `beatmapset_id`, `beatmap_md5`, `song_name`, `artist`,`title`,`version`, `creator`, `mode`, `ar`, `od`,`hp`,`cs`, `difficulty_std`, `difficulty_taiko`, `difficulty_ctb`, `difficulty_mania`, `max_combo`, `hit_length`, `bpm`, `ranked`, `latest_update`, `ranked_status_freezed`, `ranking_data`) VALUES (NULL,	 %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);", [
					self.beatmapID,
					self.beatmapSetID,
					self.fileMD5,
					self.songName.encode("utf-8", "ignore").decode("utf-8"),
					self.artist.encode("utf-8", "ignore").decode("utf-8"),
					self.title.encode("utf-8", "ignore").decode("utf-8"),
					self.version.encode("utf-8", "ignore").decode("utf-8"),
					self.creator.encode("utf-8", "ignore").decode("utf-8"),
					self.mode,
					self.AR,
					self.OD,
					self.HP,
					self.CS,
					self.starsStd,
					self.starsTaiko,
					self.starsCtb,
					self.starsMania,
					self.maxCombo,
					self.hitLength,
					self.bpm,
					self.rankedStatus if frozen == 0 else 2,
					int(time.time()),
					frozen,
					self.rankingDate if self.rankedStatus > 0 else 0
				])
			except:
				glob.db.execute("DELETE FROM beatmaps WHERE beatmap_id = %s ",[self.beatmapID])
				self.rankedStatus = rankedStatuses.NEED_UPDATE
				pass

	def setDataFromDB(self, md5):
		"""
		Set this object's beatmap data from db.

		md5 -- beatmap md5
		return -- True if set, False if not set
		"""
		# Get data from DB
		data = glob.db.fetch("SELECT * FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1", [md5])

		# Make sure the query returned something
		if data is None:
			log.warning("not found "+md5)
			return False

		# Make sure the beatmap is not an old one
		if data["difficulty_taiko"] == 0 and data["difficulty_ctb"] == 0 and data["difficulty_mania"] == 0:
			log.error("Difficulty for non-std gamemodes not found in DB, refreshing data from osu!api...")
			return False

		# Set cached data period
		expire = int(glob.conf.config["server"]["beatmapcacheexpire"])

		# If the beatmap is ranked, we don't need to refresh data from osu!api that often
		if data["ranked"] >= rankedStatuses.RANKED and data["ranked"] < rankedStatuses.QUALIFIED and data["ranked_status_freezed"] == 0:
			expire = 0
		if data["ranked"] == rankedStatuses.QUALIFIED:
			expire /= 3 
		# Make sure the beatmap data in db is not too old
		if int(expire) > 0 and time.time() > data["latest_update"]+int(expire):
			if data["ranked_status_freezed"] > 0:
				self.setDataFromDict(data)
			return False

		# Data in DB, set beatmap data
		log.debug("Got beatmap data from db")
		self.setDataFromDict(data)
		return True

	def setDataFromDict(self, data):
		"""
		Set this object's beatmap data from data dictionary.

		data -- data dictionary
		return -- True if set, False if not set
		"""
		self.songName = data["song_name"]
		self.artist = data["artist"]
		self.title = data["title"]
		self.version = data["version"]
		self.creator = data["creator"]
		self.fileMD5 = data["beatmap_md5"]
		self.rankedStatus = int(data["ranked"])
		self.rankingDate = int(data["ranking_data"])
		self.rankedStatusFrozen = int(data["ranked_status_freezed"])
		self.beatmapID = int(data["beatmap_id"])
		self.beatmapSetID = int(data["beatmapset_id"])
		self.AR = float(data["ar"])
		self.OD = float(data["od"])
		self.HP = float(data["hp"])
		self.CS = float(data["cs"])
		self.mode = int(data["mode"])
		self.starsStd = float(data["difficulty_std"])
		self.starsTaiko = float(data["difficulty_taiko"])
		self.starsCtb = float(data["difficulty_ctb"])
		self.starsMania = float(data["difficulty_mania"])
		self.maxCombo = int(data["max_combo"])
		self.hitLength = int(data["hit_length"])
		self.bpm = int(data["bpm"])
		# Ranking panel statistics
		self.playcount = int(data["playcount"]) if "playcount" in data else 0
		self.passcount = int(data["passcount"]) if "passcount" in data else 0

	def setDataFromOsuApi(self, md5, beatmapSetID):

		if md5 is None or beatmapSetID is None or beatmapSetID == 0 or md5 == "":
			return None
		"""
		Set this object's beatmap data from osu!api.

		md5 -- beatmap md5
		beatmapSetID -- beatmap set ID, used to check if a map is outdated
		return -- True if set, False if not set
		"""
		# Check if osuapi is enabled
		mainData = None
		dataStd = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=0".format(md5))
		dataTaiko = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=1".format(md5))
		dataCtb = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=2".format(md5))
		dataMania = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=3".format(md5))		
		if dataStd is not None:
			mainData = dataStd
		elif dataTaiko is not None:
			mainData = dataTaiko
		elif dataCtb is not None:
			mainData = dataCtb
		elif dataMania is not None:
			mainData = dataMania

		if mainData is not None:
			try:
				if mainData == "timeout":
					log.error(md5+": timeout")
					return False
				self.fileMD5 = md5
				self.rankedStatus = convertRankedStatus(int(mainData["approved"]))
			except Exception:
				log.error(mainData)
				return False
				pass
	
		# Can't fint beatmap by MD5. The beatmap has been updated. Check with beatmap set ID
		if mainData is None:
			log.warning("karti net v api md5={}".format(md5))
			glob.db.execute("DELETE FROM beatmaps WHERE beatmap_md5 = %s ",[md5])
			self.fileMD5 = None
			log.debug("osu!api data is None")
			mainData = osuapiHelper.osuApiRequest("get_beatmaps", "s={}".format(beatmapSetID), False)
			if mainData is not None:
				self.rankedStatus = rankedStatuses.NOT_SUBMITTED			
				for beatmap in mainData:
					if (beatmap["version"] == self.version):
						self.rankedStatus = rankedStatuses.NEED_UPDATE
						break
			return False
			
				
				

		log.debug("Got beatmap data from osu!api")
		self.songName = "{} - {} [{}]".format(mainData["artist"], mainData["title"], mainData["version"])
		self.AR = float(mainData["diff_approach"])
		self.OD = float(mainData["diff_overall"])
		self.HP = float(mainData["diff_drain"])
		self.CS = float(mainData["diff_size"])
		self.artist = mainData["artist"]
		self.title = mainData["title"]
		self.rankingDate = int(time.mktime(datetime.datetime.strptime(mainData["last_update"], "%Y-%m-%d %H:%M:%S").timetuple()))
		self.version = mainData["version"]
		self.creator = mainData["creator"]
		self.beatmapID = int(mainData["beatmap_id"])
		self.beatmapSetID = int(mainData["beatmapset_id"])
		self.mode = int(mainData["mode"])
		# Determine stars for every mode
		self.starsStd = 0
		self.starsTaiko = 0
		self.starsCtb = 0
		self.starsMania = 0
		if dataStd is not None:
			self.starsStd = dataStd["difficultyrating"]
		if dataTaiko is not None:
			self.starsTaiko = dataTaiko["difficultyrating"]
		if dataCtb is not None:
			self.starsCtb = dataCtb["difficultyrating"]
		if dataMania is not None:
			self.starsMania = dataMania["difficultyrating"]

		self.maxCombo = int(mainData["max_combo"]) if mainData["max_combo"] is not None else 0
		self.hitLength = int(mainData["hit_length"])
		if mainData["bpm"] is not None:
			self.bpm = int(float(mainData["bpm"]))
		else:
			self.bpm = -1
		return True

	def setData(self, md5, beatmapSetID):
		"""
		Set this object's beatmap data from highest level possible.

		md5 -- beatmap MD5
		beatmapSetID -- beatmap set ID
		"""
		# Get beatmap from db
		dbResult = self.setDataFromDB(md5)

		# Force refresh from osu api.
		# We get data before to keep frozen maps ranked
		# if they haven't been updated
		if dbResult == True and self.refresh:
			dbResult = False

		if not dbResult:
			log.debug("Beatmap not found in db")
			# If this beatmap is not in db, get it from osu!api
			apiResult = self.setDataFromOsuApi(md5, beatmapSetID)
			if not apiResult:	
				log.debug("beatmap not found in api")
				# If it's not even in osu!api, this beatmap is not submitted
				#self.rankedStatus = rankedStatuses.NOT_SUBMITTED
			elif self.rankedStatus != rankedStatuses.NOT_SUBMITTED and self.rankedStatus != rankedStatuses.NEED_UPDATE and self.rankedStatus != rankedStatuses.UNKNOWN:
				log.debug("foun in api")
				# We get beatmap data from osu!api, save it in db
				self.addBeatmapToDB()
		else:
			log.debug("Beatmap found in db")



	def getData(self, totalScores=0, version=4):
		"""
		Return this beatmap's data (header) for getscores

		return -- beatmap header for getscores
		"""
		# Fix loved maps for old clients
		if version < 4 and self.rankedStatus == rankedStatuses.LOVED:
			rankedStatusOutput = rankedStatuses.QUALIFIED
		else:
			rankedStatusOutput = self.rankedStatus
		data = "{}|false".format(rankedStatusOutput)
		if self.rankedStatus != rankedStatuses.NOT_SUBMITTED and self.rankedStatus != rankedStatuses.NEED_UPDATE and self.rankedStatus != rankedStatuses.UNKNOWN:
			# If the beatmap is updated and exists, the client needs more data
			data += "|{}|{}|{}\n{}\n{}\n{}\n".format(self.beatmapID, self.beatmapSetID, totalScores, self.offset, self.songName, self.rating)

		# Return the header
		return data

	def getCachedTillerinoPP(self):
		"""
		Returned cached pp values for 100, 99, 98 and 95 acc nomod
		(used ONLY with Tillerino, pp is always calculated with oppai when submitting scores)

		return -- list with pp values. [0,0,0,0] if not cached.
		"""
		data = glob.db.fetch("SELECT pp_100, pp_99, pp_98, pp_95 FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1", [self.fileMD5])
		if data is None:
			return [0,0,0,0]
		return [data["pp_100"], data["pp_99"], data["pp_98"], data["pp_95"]]

	def saveCachedTillerinoPP(self, l):
		"""
		Save cached pp for tillerino

		l -- list with 4 default pp values ([100,99,98,95])
		"""
		glob.db.execute("UPDATE beatmaps SET pp_100 = %s, pp_99 = %s, pp_98 = %s, pp_95 = %s WHERE beatmap_md5 = %s", [l[0], l[1], l[2], l[3], self.fileMD5])

def convertRankedStatus(approvedStatus):
	"""
	Convert approved_status (from osu!api) to ranked status (for getscores)

	approvedStatus -- approved status, from osu!api
	return -- rankedStatus for getscores
	"""

	approvedStatus = int(approvedStatus)
	if approvedStatus <= 0:
		return rankedStatuses.PENDING
	elif approvedStatus == 1:
		return rankedStatuses.RANKED
	elif approvedStatus == 2:
		return rankedStatuses.APPROVED
	elif approvedStatus == 3:
		return rankedStatuses.QUALIFIED
	elif approvedStatus == 4:
		return rankedStatuses.LOVED
	else:
		return rankedStatuses.UNKNOWN

def incrementPlaycount(md5, passed):
	"""
	Increment playcount (and passcount) for a beatmap

	md5 -- beatmap md5
	passed -- if True, increment passcount too
	"""
	glob.db.execute("UPDATE beatmaps SET playcount = playcount+1 WHERE beatmap_md5 = %s LIMIT 1", [md5])
	if passed:
		glob.db.execute("UPDATE beatmaps SET passcount = passcount+1 WHERE beatmap_md5 = %s LIMIT 1", [md5])