#CS ===========================================================================
; Author: Ian
; Contributor: ----
; Copyright 2025 caustic-kronos
;
; Licensed under the Apache License, Version 2.0 (the 'License');
; you may not use this file except in compliance with the License.
; You may obtain a copy of the License at
; http://www.apache.org/licenses/LICENSE-2.0
;
; Unless required by applicable law or agreed to in writing, software
; distributed under the License is distributed on an 'AS IS' BASIS,
; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
; See the License for the specific language governing permissions and
; limitations under the License.
#CE ===========================================================================

#include-once
#RequireAdmin
#NoTrayIcon

#include '../../lib/GWA2.au3'
#include '../../lib/GWA2_ID.au3'
#include '../../lib/Utils.au3'

Opt('MustDeclareVars', True)

; ==== Constants ====
Global Const $DELDRIMOR_FARM_INFORMATIONS = 'For best results, do not cheap out on heroes' & @CRLF _
	& 'I recommend using a range build to avoid pulling extra groups in crowded rooms' & @CRLF _
	& 'Recommend two healer heroes. Tested with BIP + SOS Healer.' & @CRLF _
	& '10-15mn average in NM' & @CRLF _
	& '15-20mn average in HM with cons (automatically used if HM is on)' & @CRLF _
	& 'You must have already completed the 4 map pieces and at least one' & @CRLF _
	& 'Manual run of the Dungeon Prior to running this script'

Global Const $DELDRIMOR_FARM_DURATION = 20 * 60 * 1000

Global Const $SNOWMAN_QUEST_ACCEPT_ID = 0x838201
Global Const $SNOWMAN_READY_ID = 0x84
Global Const $SNOWMAN_ACCEPT_REWARD = 0x838207

; ModelID 6268 = Koris Deeprunner
Global Const $ID_NPC_SNOWMAN_LAIR_ENTRANCE = 6268

Global $snowman_farm_setup = False
Global $snowman_highest_section_started = 1 ; tracks last shrine confirmed activated this run
Global $snowman_entrance_fail_count = 0    ; tracks consecutive failures to enter the dungeon
Global $snowman_skip_quest_setup = True   ; set True to skip quest accept/reward logic entirely

Func DeldrimorFarm()
	If Not $snowman_farm_setup And SetupDeldrimorTitleFarm() == $FAIL Then
		Info('Snowman farm setup failed, stopping farm.')
		Return $PAUSE
	EndIf
	MoveToLairSnowman()
	If GetMapID() <> $ID_SNOWMEN_LAIR Then
		$snowman_entrance_fail_count += 1
		Info('Failed to enter Snowman Lair (' & $snowman_entrance_fail_count & '/3)')
		If $snowman_entrance_fail_count >= 3 Then
			Info('Entrance failed 3 times in a row - travelling to Olafstead to reset')
			DistrictTravel($ID_OLAFSTEAD, $district_name)
			RandomSleep(1000)
			$snowman_farm_setup = False
			$snowman_entrance_fail_count = 0
		EndIf
		Return $SUCCESS ; let outer loop retry
	EndIf
	$snowman_entrance_fail_count = 0
	Local $result = FarmLairSnowman()
	DistrictTravel($ID_UMBRAL_GROTTO, $district_name)
	Return $result
EndFunc

Func SetupDeldrimorTitleFarm()
	DistrictTravel($ID_UMBRAL_GROTTO, $district_name)
	SwitchToHardModeIfEnabled()
	
	If $snowman_skip_quest_setup Then
		Info('Quest setup skipped (snowman_skip_quest_setup = True)')
		$snowman_farm_setup = True
		Return $SUCCESS
	EndIf

	If IsQuestReward($ID_QUEST_LOST_TREASURE_OF_KING_HUNDAR) Then
		Info('Quest Reward Found! Gathering Quest Reward')
		MoveTo(-23886, 13881)
		Local $questNPC = GetAgentByModelID($ID_NPC_SNOWMAN_LAIR_ENTRANCE)
		RandomSleep(750)
		TakeQuestReward($questNPC, $ID_QUEST_LOST_TREASURE_OF_KING_HUNDAR, $SNOWMAN_ACCEPT_REWARD)
		RandomSleep(750)
		Info('Zoning to Olafsted to Refresh Quest')
		DistrictTravel($ID_OLAFSTEAD, $district_name)
		Sleep(750)
		Info('Zoning back to Umbral')
		DistrictTravel($ID_UMBRAL_GROTTO, $district_name)
		RandomSleep(1000)
	EndIf

	If IsQuestNotFound($ID_QUEST_LOST_TREASURE_OF_KING_HUNDAR) Then
		Info('Setting up Snowman Lair')
		RandomSleep(750)
		MoveTo(-23886, 13881)
		Local $questNPC = GetAgentByModelID($ID_NPC_SNOWMAN_LAIR_ENTRANCE)
		TakeQuest($questNPC, $ID_QUEST_LOST_TREASURE_OF_KING_HUNDAR, $SNOWMAN_QUEST_ACCEPT_ID)
	EndIf

	If IsQuestActive($ID_QUEST_LOST_TREASURE_OF_KING_HUNDAR) Then
		$snowman_farm_setup = True
		Info('Quest in the logbook. Good to go!')
		Return $SUCCESS
	Else
		Return $FAIL
	EndIf
EndFunc

Func MoveToLairSnowman()
	Info('Moving to Lair')
	Local $questNPC = GetAgentByModelID($ID_NPC_SNOWMAN_LAIR_ENTRANCE)
	GoToNPC($questNPC)
	RandomSleep(500)
	Dialog(0x84)
	WaitMapLoading($ID_SNOWMEN_LAIR, 10000, 2000)
EndFunc

Func FarmLairSnowman()
	If GetMapID() <> $ID_SNOWMEN_LAIR Then Return $FAIL

	$snowman_highest_section_started = 1
	Local $section = 1
	While $section <= 3
		Local $result
		Switch $section
			Case 1
				$snowman_highest_section_started = 1
				$result = _RunSection1Snowman()
			Case 2
				$snowman_highest_section_started = 2
				$result = _RunSection2Snowman()
			Case 3
				$snowman_highest_section_started = 3
				$result = _RunSection3Snowman()
		EndSwitch

		If $result == $SUCCESS Then
			$section += 1
		Else
			; Wipe detected - wait for rez then sample position up to 3 times with a
			; short pause between each to avoid stale coords immediately after rez.
			; Take the highest shrine detected across all samples, then apply the
			; $snowman_highest_section_started cap so we never jump past a shrine
			; that was never actually activated this run.
			Local $rezzed = _WaitForPlayerAlive()
			; If the timeout fired or the map changed, the player was likely kicked to the
			; outpost by 60% death penalty (HM). Restart the whole farm run.
			If Not $rezzed Or GetMapID() <> $ID_SNOWMEN_LAIR Then
				Info('Player no longer in dungeon after wipe - restarting farm run.')
				$snowman_farm_setup = False
				Return $SUCCESS
			EndIf
			Local $posSection = 1
			For $attempt = 1 To 3
				Local $detected = _GetCurrentSnowmanSection()
				If $detected > $posSection Then $posSection = $detected
				If $attempt < 3 Then RandomSleep(3000)
			Next
			$section = ($posSection > $snowman_highest_section_started) ? $snowman_highest_section_started : $posSection
		EndIf
	WEnd

	$snowman_farm_setup = False
	Return $SUCCESS
EndFunc


;~ Waits until the player is alive again after a death or full wipe.
;~ Returns True when the party is no longer fully wiped.
;~ Returns False if the party has been wiped for more than ~50 seconds without recovering
;~ (e.g. 60% death penalty kick to outpost in HM - the player is no longer dead so the
;~ loop exits, but they will have been transported out of the dungeon).
Func _WaitForPlayerAlive()
	Info('Party wiped - waiting for resurrection...')
	Local $polls = 0
	While IsPlayerAndPartyWiped()
		RandomSleep(2000)
		$polls += 1
		If $polls >= 25 Then
			Info('Wipe timeout reached after ~50s - assuming kicked to outpost or stuck.')
			Return False
		EndIf
	WEnd
	RandomSleep(2000)
	Info('Resurrected, determining section...')
	Return True
EndFunc


;~ After a wipe+rez, determine which section to run based on which shrine the player
;~ is standing near. Shrines are 10,000+ units apart so a 3000-unit check is unambiguous.
Func _GetCurrentSnowmanSection()
	Local $me = GetMyAgent()
	If IsAgentInRange($me, -16005, -10679, 3000) Then
		Info('Detected near shrine 3, resuming section 3.')
		Return 3
	EndIf
	If IsAgentInRange($me, -12482, 3924, 3000) Then
		Info('Detected near shrine 2, resuming section 2.')
		Return 2
	EndIf
	Info('Detected near shrine 1 (or unknown position), restarting section 1.')
	Return 1
EndFunc


;~ Wrapper for MoveAggroAndKillInRange that blocks on player death until either the
;~ player is rezzed by a hero (then continues) or the entire party wipes (then fails).
;~ Prevents rapid ghost-execution of steps while the player is dead mid-section.
Func _SnowmanMove($x, $y, $log = '')
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	If MoveAggroAndKillInRange($x, $y, $log) == $FAIL Then Return $FAIL
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	Return $SUCCESS
EndFunc


;~ Blocks while the player is dead but heroes are still alive (waiting for hero rez).
;~ Returns True when player is alive again, False if the entire party has wiped.
Func _WaitForPlayerRezOrWipe()
	While IsPlayerDead()
		If IsPlayerAndPartyWiped() Then Return False
		RandomSleep(2000)
	WEnd
	Return True
EndFunc


;~ Section 1: Starting shrine to enemies at shrine 2 cleared.
;~ Wipe here => party rezes at shrine 1 (-14131, 15437).
Func _RunSection1Snowman()
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	Info('Getting Blessing')
	GoToNPC(GetNearestNPCToCoords(-14131, 15437))
	RandomSleep(500)
	Dialog(0x84)
	RandomSleep(500)

	If IsHardmodeEnabled() Then UseConset()
	UseConsumable($ID_BIRTHDAY_CUPCAKE, True)
	UseConsumable($ID_HONEYCOMB, True)


	If _SnowmanMove(-14610, 12352, 'First Snowmen Block') == $FAIL Then Return $FAIL
	If _SnowmanMove(-16585, 8741, 'Second Snowmen Block') == $FAIL Then Return $FAIL
	If _SnowmanMove(-17949, 6797, 'Mopping up any snowmen') == $FAIL Then Return $FAIL
	Info('Time to avoid Snowballs')
	RandomSleep(10000)
	If _SnowmanMove(-19169, 5355, 'Lonely Snowmen 1') == $FAIL Then Return $FAIL
	If _SnowmanMove(-17196, 1934, 'Lots of Snowmen') == $FAIL Then Return $FAIL
	If _SnowmanMove(-15396, 2887, 'Bridge of Snowmen') == $FAIL Then Return $FAIL
	If _SnowmanMove(-14392, 3759, 'Over The Bridge of Snowmen') == $FAIL Then Return $FAIL
	If _SnowmanMove(-12482, 3924, 'Murder Over The Bridge of Snowmen') == $FAIL Then Return $FAIL
	Return $SUCCESS
EndFunc


;~ Section 2: Shrine 2 blessing through key collection, activating shrine 3 at end.
;~ Wipe here => party rezes at shrine 2 (-12482, 3924).
Func _RunSection2Snowman()
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	Info('Get New Blessing')
	GoToNPC(GetNearestNPCToCoords(-12482, 3924))
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	Info('Moving to Snowman Channel')
	If MoveTo(-14392, 3759) == $FAIL Then Return $FAIL
	If MoveTo(-14413, 2483) == $FAIL Then Return $FAIL

	If _SnowmanMove(-13464, -687, 'Channel of Snowmen') == $FAIL Then Return $FAIL
	Info('Wait to Heal after Ice Spouts')
	RandomSleep(5000)
	If _SnowmanMove(-12989, -731, 'Lonely Snowman 2') == $FAIL Then Return $FAIL
	If _SnowmanMove(-12802, -4446, 'Remainder of Snowmen') == $FAIL Then Return $FAIL
	Info('Wait to Heal after Ice Spouts')
	RandomSleep(10000)
	Info('Beware of Avalanches')
	If _SnowmanMove(-13176, -6779, 'Third Snowmen Block') == $FAIL Then Return $FAIL
	If _SnowmanMove(-13676, -9799, 'Fourth Snowmen Block') == $FAIL Then Return $FAIL
	Info('Time To Get a Key')
	If _SnowmanMove(-9646, -10924, 'Key of Snowmen') == $FAIL Then Return $FAIL
	PickUpItems()

	Info('Get New Blessing')
	MoveTo(-16005, -10679)
	GoToNPC(GetNearestNPCToCoords(-16005, -10679))
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	Return $SUCCESS
EndFunc


;~ Section 3: Shrine 3 blessing through Freezie boss and final chest.
;~ Wipe here => party rezes at shrine 3 (-16005, -10679).
Func _RunSection3Snowman()
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL
	; Swing back to the key area before anything else. Enemies are already dead so a
	; plain move is safe. This guarantees the key is in inventory even when PickUpItems()
	; missed it at the end of section 2, preventing an infinite loop at the locked door.
	Info('Ensuring key is in inventory')
	If _SnowmanMove(-9646, -10924) == $FAIL Then Return $FAIL
	PickUpItems()

	Info('Get New Blessing')
	GoToNPC(GetNearestNPCToCoords(-16005, -10679))
	If Not _WaitForPlayerRezOrWipe() Then Return $FAIL

	Info('Time to open the door')
	If _SnowmanMove(-15641, -11961, 'Door of Snowmen') == $FAIL Then Return $FAIL
	Info('Open dungeon door')
	ClearTarget()
	Sleep(2000)
	; Doubled to secure bot
	For $i = 1 To 2
		MoveTo(-15483, -12236)
		TargetNearestItem()
		RandomSleep(500)
		ActionInteract()
		ActionInteract()
		RandomSleep(500)
	Next

	If _SnowmanMove(-17345, -13797, 'Circle of Snowmen') == $FAIL Then Return $FAIL
	Info('Time for Freezie')
	MoveTo(-14303, -17111)
	If _SnowmanMove(-13843, -17345, 'Freezie Snowmen Block') == $FAIL Then Return $FAIL

	Info('Pickup Key')
	PickUpItems()
	Info('Opening Boss door')
	MoveTo(-11274, -17984)
	Sleep(2000)
	; Doubled to secure bot
	For $i = 1 To 2
		MoveTo(-11274, -17984)
		TargetNearestItem()
		RandomSleep(500)
		ActionInteract()
		ActionInteract()
		RandomSleep(500)
	Next

	Info('Having a cry about beer')
	MoveTo(-7770, -18740)
	Info('Waiting to finish tears')
	ClearTarget()
	Sleep(70000)
	; Doubled to try securing the looting
	For $i = 1 To 2
		MoveTo(-7770, -18740)
		Info('Opening Wintersday chest')
		TargetNearestItem()
		ActionInteract()
		RandomSleep(2500)
		PickUpItems()
	Next
	Return $SUCCESS
EndFunc