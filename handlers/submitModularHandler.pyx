import base64
import collections
import json
import os
import sys
import traceback
import threading
from urllib.parse import urlencode
from dhooks.discord_hooks import Webhook
import datetime
import requests
import tornado.gen
import tornado.web

from common import generalUtils
from common.constants import mods
from objects import beatmap
from objects import score
from objects import scoreboard
from common.constants import gameModes
from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from constants.exceptions import ppCalcException
from helpers import aeshelper
from helpers import leaderboardHelper
from helpers import leaderboardHelperRelax
from helpers import replayHelper
from objects import glob
from common.sentry import sentry
from secret import butterCake

MODULE_NAME = "submit_modular"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-submit-modular.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	#@sentry.captureTornado
	def asyncPost(self):
		try:
			# Resend the score in case of unhandled exceptions
			keepSending = True

			# Get request ip
			ip = self.getRequestIP()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# Check arguments
			if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# TODO: Maintenance check

			# Get parameters and IP
			scoreDataEnc = self.get_argument("score")
			iv = self.get_argument("iv")
			password = self.get_argument("pass")
			ip = self.getRequestIP()

			# Get bmk and bml (notepad hack check)
			if "bmk" in self.request.arguments and "bml" in self.request.arguments:
				bmk = self.get_argument("bmk")
				bml = self.get_argument("bml")
			else:
				bmk = None
				bml = None
			
			# Get right AES Key
			if "osuver" in self.request.arguments:
				osuver = int(self.get_argument("osuver"))
				aeskey = "osu!-scoreburgr---------{}".format(self.get_argument("osuver"))
			else:
				aeskey = "h89f2-890h2h89b34g-h80g134n90133"

			# Get score data
			log.debug("Decrypting score data...")
			scoreData = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(":")
			username = scoreData[1].strip()


			# Login and ban check
			userID = userUtils.getID(username)
			#glob.db.execute("INSERT INTO private (userid, c1) VALUES (%s, %s)",[userID, self.get_argument("c1")])
			
			# User exists check
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
			# Bancho session/username-pass combo check
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			# 2FA Check
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, userID, ip)
			# Generic bancho session check
			#if not userUtils.checkBanchoSession(userID):
				# TODO: Ban (see except exceptions.noBanchoSessionException block)
			#	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)
			# Data length check
			if len(scoreData) < 16:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get restricted
			restricted = userUtils.isRestricted(userID)

			# Create score object and set its data
			log.info("{} has submitted a score on {}...".format(username, scoreData[0]))
			s = score.score()
			s.setDataFromScoreData(scoreData)
			
			if s.completed == -1:
				# Duplicated score
				log.warning("Duplicated score detected, this is normal right after restarting the server")
				return

			oldStats = userUtils.getUserStats(userID, s.gameMode)
			if ((s.passed == False and s.score < 1000) or s.score < 10):
				return
			# Get beatmap info
			beatmapInfo = beatmap.beatmap()
			beatmapInfo.setDataFromDB(s.fileMd5)
			
			# Make sure the beatmap is submitted and updated
			#if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
			#	log.debug("Beatmap is not submitted/outdated/unknown. Score submission aborted.")
			#	return

			# Check if the ranked status is allowed
			if beatmapInfo.rankedStatus not in glob.conf.extra["_allowed_beatmap_rank"]:
				log.debug("Beatmap's rankstatus is not allowed to be submitted. Score submission aborted.")
				return
				
			# Calculate PP
			midPPCalcException = None
			try:
				s.calculatePP()
			except Exception as e:
				# Intercept ALL exceptions and bypass them.
				# We want to save scores even in case PP calc fails
				# due to some rippoppai bugs.
				# I know this is bad, but who cares since I'll rewrite
				# the scores server again.
				log.error("Caught an exception in pp calculation, re-raising after saving score in db")
				s.pp = 0
				midPPCalcException = e

			# Restrict obvious cheaters
			if (glob.conf.extra["lets"]["submit"]["max-std-pp"] >= 0 and s.pp >= glob.conf.extra["lets"]["submit"]["max-std-pp"] and s.gameMode == gameModes.STD) and restricted == False:
				userUtils.restrict(userID)
				restricted = True
				userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
				log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")

			# Check notepad hack
			if bmk is None and bml is None:
				# No bmk and bml params passed, edited or super old client
				#log.warning("{} ({}) most likely submitted a score from an edited client or a super old client".format(username, userID), "cm")
				pass
			elif bmk != bml and restricted == False:
				# bmk and bml passed and they are different, restrict the user
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to notepad hack")
				log.warning("**{}** ({}) has been restricted due to notepad hack".format(username, userID), "cm")
				return
			# Save score in db
			if bool(s.mods & 128) == True:
				s.saveRelaxScoreInDB()
			else:
				s.saveScoreInDB()
			# Let the api know of this score
			if s.scoreID:
				glob.redis.publish("api:score_submission", s.scoreID)
				
			# Re-raise pp calc exception after saving score, cake, replay etc
			# so Sentry can track it without breaking score submission
			if midPPCalcException is not None:
				raise ppCalcException(midPPCalcException)

			# Client anti-cheat flags
			'''ignoreFlags = 4
			if glob.debug == True:
				# ignore multiple client flags if we are in debug mode
				ignoreFlags |= 8
			haxFlags = (len(scoreData[17])-len(scoreData[17].strip())) & ~ignoreFlags
			if haxFlags != 0 and restricted == False:
				userHelper.restrict(userID)
				userHelper.appendNotes(userID, "-- Restricted due to clientside anti cheat flag ({}) (cheated score id: {})".format(haxFlags, s.scoreID))
				log.warning("**{}** ({}) has been restricted due clientside anti cheat flag **({})**".format(username, userID, haxFlags), "cm")'''

			# Make sure process list has been passed

			if s.score < 0 or s.score > (2 ** 63) - 1:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to negative score (score submitter)")

			# Make sure the score is not memed
			if s.gameMode == gameModes.MANIA and s.score > 1000000:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to mania score > 1000000 (score submitter)")

			# Ci metto la faccia, ci metto la testa e ci metto il mio cuore
			if ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
					or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0)\
					or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0):
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Impossible mod combination {} (score submitter)".format(s.mods))
				log.warning("**{}** ({}) has been restricted due to impossible mod combination {} (score submitter)".format(username, userID,s.mods), "cm")

			if s.completed == 3 and "pl" not in self.request.arguments and restricted == False and osuver < 20180322:
				#userUtils.restrict(userID)
				#userUtils.appendNotes(userID, "Restricted due to missing process list while submitting a score (most likely he used a score submitter)")
				log.warning("**{}** ({}) has been restricted due to missing process list osuver: {}".format(username, userID, osuver), "cm")

			if s.mods & 8320 == 8320:
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to sunpy cheat")
				log.warning("**{}** ({}) has been restricted due to sunpy cheat", "cm")
				return

			# Save replay

			if s.passed == True:
				butterCake.bake(self, s)


			if s.passed == True and s.completed == 3:
				if "score" not in self.request.files:
					if not restricted:
						# Ban if no replay passed
						userUtils.restrict(userID)
						userUtils.appendNotes(userID, "Restricted due to missing replay while submitting a score (most likely he used a score submitter)")
						log.warning("**{}** ({}) has been restricted due to replay not found on map {}".format(username, userID, s.fileMd5), "cm")
				else:
					# Otherwise, save the replay
					log.debug("Saving replay ({})...".format(s.scoreID))
					replay = self.request.files["score"][0]["body"]
					with open(".data/replays/replay_{}.osr".format(s.scoreID), "wb") as f:
						f.write(replay)
						
					# We run this in a separate thread to avoid slowing down scores submission,
					# as cono needs a full replay
					threading.Thread(target=lambda: glob.redis.publish(
						"cono:analyze", json.dumps({
							"score_id": s.scoreID,
							"beatmap_id": beatmapInfo.beatmapID,
							"user_id": s.playerUserID,
							"replay_data": base64.b64encode(
								replayHelper.buildFullReplay(s.scoreID, rawReplay=replay)
							).decode()
						})
					)).start()

			# Make sure the replay has been saved (debug)
			if not os.path.isfile(".data/replays/replay_{}.osr".format(s.scoreID)) and s.completed == 3:
				log.error("Replay for score {} not saved!!".format(s.scoreID), "bunker")

			# Update beatmap playcount (and passcount)
			beatmap.incrementPlaycount(s.fileMd5, s.passed)

			# Get "before" stats for ranking panel (only if passed)
			if s.passed:
				# Get stats and rank
				oldUserData = glob.userStatsCache.get(userID, s.gameMode)
				oldRank = leaderboardHelper.getUserRank(userID, s.gameMode)

				# Try to get oldPersonalBestRank from cache
				oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
				if oldPersonalBestRank == 0:
					# oldPersonalBestRank not found in cache, get it from db
					oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					oldScoreboard.setPersonalBest()
					oldPersonalBestRank = oldScoreboard.personalBestRank if oldScoreboard.personalBestRank > 0 else 0

			# Always update users stats (total/ranked score, playcount, level, acc and pp)
			# even if not passed
			log.debug("Updating {}'s stats...".format(username))
			userUtils.updateStats(userID, s)

			# Get "after" stats for ranking panel
			# and to determine if we should update the leaderboard
			# (only if we passed that song)
			if s.passed:
				# Get new stats
				newUserData = userUtils.getUserStats(userID, s.gameMode)
				glob.userStatsCache.update(userID, s.gameMode, newUserData)
				if s.completed == 3 and bool(s.mods & 128) == False:
					leaderboardHelper.update(userID, newUserData["pp"], s.gameMode)
				elif s.completed == 3 and bool(s.mods & 128) == True:
					leaderboardHelperRelax.update(userID, newUserData["pp"], s.gameMode)				

			# TODO: Update total hits and max combo
			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# IP log
			userUtils.IPLog(userID, ip)

			# Score submission and stats update done
			log.debug("Score submission and user stats update done!")

			# Score has been submitted, do not retry sending the score if
			# there are exceptions while building the ranking panel
			keepSending = False
			# Output ranking panel only if we passed the song
			# and we got valid beatmap info from db
			if beatmapInfo is not None and beatmapInfo != False and s.passed == True:
				log.debug("Started building ranking panel")

				# Trigger bancho stats cache update
				glob.redis.publish("peppy:update_cached_stats", userID)

				# Get personal best after submitting the score
				newScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, True)
				newScoreboard.setPersonalBest()

				# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
				if bool(s.mods & 128):
					rankInfo = leaderboardHelperRelax.getRankInfo(userID, s.gameMode)
				else:
					rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode)
				
				playsInfo = glob.db.fetch("SELECT * FROM beatmap_plays WHERE beatmap_md5 = %s",[beatmapInfo.fileMD5])
				if playsInfo is None:
					playsInfo = {'passcount': 1, 'playcount': 1}
				# Output dictionary
				output = collections.OrderedDict()
				output["beatmapId"] = beatmapInfo.beatmapID
				output["beatmapSetId"] = beatmapInfo.beatmapSetID
				output["beatmapPlaycount"] = playsInfo['playcount']
				output["beatmapPasscount"] = playsInfo['passcount']
				output["approvedDate"] = datetime.datetime.fromtimestamp(int(beatmapInfo.rankingDate)).strftime('%Y-%m-%d %H:%M:%S\n')
				output["chartId"] = "overall"
				output["chartName"] = "Overall Ranking"
				output["chartEndDate"] = ""
				output["beatmapRankingBefore"] = oldPersonalBestRank
				output["beatmapRankingAfter"] = newScoreboard.personalBestRank
				output["rankedScoreBefore"] = oldUserData["rankedScore"]
				output["rankedScoreAfter"] = newUserData["rankedScore"]
				output["totalScoreBefore"] = oldUserData["totalScore"]
				output["totalScoreAfter"] = newUserData["totalScore"]
				output["playCountBefore"] = newUserData["playcount"]
				output["accuracyBefore"] = float(oldUserData["accuracy"])/100
				output["accuracyAfter"] = float(newUserData["accuracy"])/100
				output["rankBefore"] = oldRank
				output["rankAfter"] = rankInfo["currentRank"]
				output["toNextRank"] = rankInfo["difference"]
				output["toNextRankUser"] = rankInfo["nextUsername"]
				output["achievements"] = ""
				try:
					# std only
					if s.gameMode != 0:
						raise Exception

					# Get best score if
					if (s.mods & mods.RELAX) > 0 or (s.mods & mods.RELAX2) > 0:
						bestID = int(glob.db.fetch("SELECT id FROM scores_rx WHERE userid = %s AND play_mode = %s AND completed = 3 ORDER BY pp DESC LIMIT 1", [userID, s.gameMode])["id"])
					else: 
						bestID = int(glob.db.fetch("SELECT id FROM scores WHERE userid = %s AND play_mode = %s AND completed = 3 ORDER BY pp DESC LIMIT 1", [userID, s.gameMode])["id"])
						if bestID == s.scoreID:
							# Dat pp achievement
							output["achievements-new"] = "all-secret-jackpot+Here come dat PP+Oh shit waddup"
						else:
							raise Exception
				except:
						# No achievement
						output["achievements-new"] = ""
				output["onlineScoreId"] = s.scoreID

				# Build final string
				msg = ""
				for line, val in output.items():
					msg += "{}:{}".format(line, val)
					if val != "\n":
						if (len(output) - 1) != list(output.keys()).index(line):
							msg += "|"
						else:
							msg += "\n"

				# Some debug messages
				log.debug("Generated output for online ranking screen!")
				log.debug(msg)
				s.calculateAccuracy()
				# scores discord/VK bot
				userStats = userUtils.getUserStats(userID, s.gameMode)
				if s.completed == 3 and restricted == False and beatmapInfo.rankedStatus >= rankedStatuses.RANKED and s.pp > 10:
					glob.redis.publish("scores:new_score", json.dumps({
					"gm":s.gameMode,
					"user":{"username":username, "userID": userID, "rank":newUserData["gameRank"],"oldaccuracy":oldStats["accuracy"],"accuracy":newUserData["accuracy"], "oldpp":oldStats["pp"],"pp":newUserData["pp"]},
					"score":{"scoreID": s.scoreID, "mods":s.mods, "accuracy":s.accuracy, "missess":s.cMiss, "combo":s.maxCombo, "pp":s.pp, "rank":newScoreboard.personalBestRank, "ranking":s.rank},
					"beatmap":{"beatmapID": beatmapInfo.beatmapID, "beatmapSetID": beatmapInfo.beatmapSetID, "max_combo":beatmapInfo.maxCombo, "song_name":beatmapInfo.songName}
					}))


				# replay anticheat

				if (s.mods & mods.RELAX < 1 and s.mods & mods.RELAX2 < 1) and s.completed == 3 and restricted == False and beatmapInfo.rankedStatus >= rankedStatuses.RANKED and s.pp > 90 and s.gameMode == 0:
					glob.redis.publish("hax:newscore", json.dumps({
					"username":username,
					"userID": userID,
					"scoreID": s.scoreID,
					"mods": s.mods,
					"beatmapID": beatmapInfo.beatmapID,
					"beatmapSetID": beatmapInfo.beatmapSetID,
					"pp":s.pp,
					"rawoldpp":oldStats["pp"],
					"rawpp":newUserData["pp"]
					}))
				# send message to #announce if we're rank #1
				if newScoreboard.personalBestRank < 51 and s.completed == 3 and restricted == False and beatmapInfo.rankedStatus >= rankedStatuses.RANKED:
					userUtils.logUserLog("achieved #{} rank on ".format(newScoreboard.personalBestRank),s.fileMd5, userID, s.gameMode)
					if newScoreboard.personalBestRank < 2:
						annmsg = "[{} - https://new.vipsu.cf/u/{}] achieved rank #1 on [https://osu.ppy.sh/b/{} {}] ({}) {}pp".format(username, userID, beatmapInfo.beatmapID, beatmapInfo.songName, gameModes.getGamemodeFull(s.gameMode),round(s.pp, 2))
						params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": annmsg})
						requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
						if (len(newScoreboard.scores) > 2):
							userUtils.logUserLog("has lost first place on ",s.fileMd5, newScoreboard.scores[2].playerUserID, s.gameMode)	
								
					# upon new #1 = send the score to the discord bot
					# s=0 = regular && s=1 = relax
					ppGained = newUserData["pp"] - oldUserData["pp"]
					gainedRanks = oldRank - rankInfo["currentRank"]
					# webhook to discord

					#TEMPORARY mods handle
					ScoreMods = ""
					
					if s.mods == 0:
						ScoreMods += "nomod"
					if s.mods & mods.NOFAIL > 0:
						ScoreMods += "NF"
					if s.mods & mods.EASY > 0:
						ScoreMods += "EZ"
					if s.mods & mods.HIDDEN > 0:
						ScoreMods += "HD"
					if s.mods & mods.HARDROCK > 0:
						ScoreMods += "HR"
					if s.mods & mods.DOUBLETIME > 0:
						ScoreMods += "DT"
					if s.mods & mods.HALFTIME > 0:
						ScoreMods += "HT"
					if s.mods & mods.FLASHLIGHT > 0:
						ScoreMods += "FL"
					if s.mods & mods.SPUNOUT > 0:
						ScoreMods += "SO"
					if s.mods & mods.TOUCHSCREEN > 0:
						ScoreMods += "TD"
					if s.mods & mods.RELAX > 0:
						ScoreMods += "RX"
					if s.mods & mods.RELAX2 > 0:
						ScoreMods += "AP"
					type = glob.conf.extra["lets"]["discord"]["type"]
					url = glob.conf.extra["lets"]["discord"]["webhook"]

					if type == "regular":
						embed = Webhook(url, color=0x35b75c)
						embed.set_author(name=username.encode().decode("ASCII", "ignore"), icon='https://i.imgur.com/rdm3W9t.png')
						embed.set_desc("Achieved #1 on mode **{}**, {} +{} on regular!".format(
						gameModes.getGamemodeFull(s.gameMode),
						beatmapInfo.songName.encode().decode("ASCII", "ignore"),
						ScoreMods
						))
						embed.add_field(name='Total: {}pp'.format(
						float("{0:.2f}".format(s.pp))
						),value='Gained: +{}pp'.format(
						float("{0:.2f}".format(ppGained))
						))
						embed.add_field(name='Actual rank: {}'.format(
						rankInfo["currentRank"]
						),value='[Download Link](http://mirror.catgirls.fun/d/{})'.format(
						beatmapInfo.beatmapSetID
						))
						embed.set_image('https://assets.ppy.sh/beatmaps/{}/covers/cover.jpg'.format(
						beatmapInfo.beatmapSetID
						))
						embed.post()
					else:
						url = 'https://discordapp.com/api/webhooks/485539881624403998/nvz14NtiTZWI4FIVLzZAQaPNiD0TmBF2GvSqcW3EX0p4tJfT3lLJ7IPeegbR3_3oBgPi'
						embed = Webhook(url, color=0x9627c5)
						embed.set_author(name=username.encode().decode("ASCII", "ignore"), icon='https://i.imgur.com/rdm3W9t.png')
						embed.set_desc("Achieved #1 on mode **{}**, {} +{} on relax!".format(
						gameModes.getGamemodeFull(s.gameMode),
						beatmapInfo.songName.encode().decode("ASCII", "ignore"),
						ScoreMods
						))
						embed.add_field(name='Total: {}pp'.format(
						float("{0:.2f}".format(s.pp))
						),value='Gained: +{}pp'.format(
						float("{0:.2f}".format(ppGained))
						))
						embed.add_field(name='Actual rank: {}'.format(
						rankInfo["currentRank"]
						),value='[Download Link](http://mirror.catgirls.fun/d/{})'.format(
						beatmapInfo.beatmapSetID
						))
						embed.set_image('https://assets.ppy.sh/beatmaps/{}/covers/cover.jpg'.format(
						beatmapInfo.beatmapSetID
						))
						embed.post()
						
				# Write message to client
				self.write(msg)
			else:
				# No ranking panel, send just "ok"
				self.write("ok")

			# Send username change request to bancho if needed
			# (key is deleted bancho-side)
			newUsername = glob.redis.get("ripple:change_username_pending:{}".format(userID))
			if newUsername is not None:
				log.debug("Sending username change request for user {} to Bancho".format(userID))
				glob.redis.publish("peppy:change_username", json.dumps({
					"userID": userID,
					"newUsername": newUsername.decode("utf-8")
				}))

			# Datadog stats
			glob.dog.increment(glob.DATADOG_PREFIX+".submitted_scores")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass")
		except exceptions.need2FAException:
			# Send error pass to notify the user
			# resend the score at regular intervals
			# for users with memy connection
			self.set_status(408)
			self.write("error: 2fa")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.noBanchoSessionException:
			# We don't have an active bancho session.
			# Don't ban the user but tell the client to send the score again.
			# Once we are sure that this error doesn't get triggered when it
			# shouldn't (eg: bancho restart), we'll ban users that submit
			# scores without an active bancho session.
			# We only log through schiavo atm (see exceptions.py).
			self.set_status(408)
			self.write("error: pass")
		except:
			# Try except block to avoid more errors
			try:
				log.error("Unknown error in {}!\n```{}\n{}```".format(MODULE_NAME, sys.exc_info(), traceback.format_exc()))
				if glob.sentry:
					yield tornado.gen.Task(self.captureException, exc_info=True)
			except:
				pass

			# Every other exception returns a 408 error (timeout)
			# This avoids lost scores due to score server crash
			# because the client will send the score again after some time.
			if keepSending:
				self.set_status(408)