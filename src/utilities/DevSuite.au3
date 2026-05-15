#CS ===========================================================================
; Author: caustic-kronos (aka Kronos, Night, Svarog)
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

#include '../../lib/GWA2_ID_Maps.au3'
#include '../../lib/GWA2_ID_Skills.au3'
#include '../../lib/GWA2_ID.au3'
#include '../../lib/Utils-Agents.au3'
#include '../../lib/Utils-Console.au3'
#include '../../lib/Utils-Storage.au3'
#include '../../lib/Utils.au3'

#include <array.au3>
#include <WinAPIDiag.au3>


; ==== Constants ====
Global Const $DEV_SUITE_INFORMATIONS = 'Just a dev suite.'

;Global $underworld_fight_options = CloneDictMap($Default_MoveAggroAndKill_Options)
;Global $underworld_player_profession = $ID_RITUALIST

;~ Main method from utils, used only to run dev tests
Func RunDevSuite()
    ;GetMyCoords()
    ;DhuumSetup()
    ;DhuumStart()

    ;Local $myHealth = DllStructGetData(GetMyAgent(), 'HealthPercent')
    ;Local $Reaper_Labyrinth = GetNearestNPCToCoords(-5694, 12772)
    ;Local $Reaper_ChaosPlanes = GetNearestNPCToCoords(11306, -17893)

    ;Info('Info: ' & QuestObjectives($ID_QUEST_TERRORWEB_QUEEN))

    ;If TheNightmanComethDev() == $SUCCESS Then Return $PAUSE

    ;Info('Test: ' & GetAttributeByID($ID_FAST_CASTING))

    GetEffects()

    Return $PAUSE
EndFunc

;~ Returns all active effect structs for player (0) or hero index.
Func GetEffects($heroIndex = 0)
	Local $effects = GetEffect(0, $heroIndex)
    Local $effectStr = ''
	If $effects == Null Then
		Local $empty[0]
		Return $empty
	EndIf
    For $i = 0 To UBound($effects) - 1
        $effectStr &= DllStructGetData($effects[$i], 'SkillID') & ' '
    Next
    Info('Active effect SkillIDs: ' & StringStripWS($effectStr, 2))
	Return $effects
EndFunc


;~ Return quest objectives hex string
Func QuestObjectives($questID)
	Local $quest = GetQuestByID($questID)
	Local $questObjectives = $ID_QUEST_NOT_FOUND
	If $quest <> Null Then $questObjectives = DllStructGetData($quest, 'Objectives')
	Return $questObjectives
EndFunc


Func GetMyCoords()
    Local $me = GetMyAgent()
    Local $myX = DllStructGetData($me, 'X')
    Local $myY = DllStructGetData($me, 'Y')
    Info('My position: ' & $myX & ', ' & $myY)
    Return $PAUSE
EndFunc


Func DhuumSetup()
    CancelAllHeroes()
    Sleep(2000)
    CommandHero(1, -17623, 17380)
    CommandHero(2, -17623, 17380)
    CommandHero(3, -17623, 17380)
    CommandHero(4, -17623, 17380)
    CommandHero(5, -17623, 17380)
    CommandHero(6, -17623, 17380)
    CommandHero(7, -17623, 17380)
    Sleep(2000)
    Return $PAUSE
EndFunc


Func DhuumStart()
    CancelAllHeroes()
    Sleep(2000)
    CommandHero(1, -17623, 17380)
    CommandHero(2, -17623, 17380)
    CommandHero(3, -17623, 17380)
    CommandHero(4, -17623, 17380)
    CommandHero(5, -17623, 17380)
    CommandHero(6, -17623, 17380)
    CommandHero(7, -17623, 17380)
    Sleep(2000)
    Local $me = GetMyAgent()
    Local $King_Frozenwind = GetNearestNPCToCoords(-12136, 17270)
    GoToNPC($King_Frozenwind)
    Sleep(250)
    Dialog(0x846901)
    Info('Cancelling all heroes')
    CancelAllHeroes()
    Sleep(1400)
    Info('Dropping Recall')
    DropBuff($ID_RECALL, $me)
    Return IsPlayerOrPartyAlive() ? $SUCCESS : $FAIL
EndFunc


Func TheNightmanComethDev()
    TeleportBackToIceWastes($Reaper)
	MoveAggroAndKill(96, 21486)
	MoveAggroAndKill(-6107, 19400)
	MoveAggroAndKill(-9520, 17293)
    Info('Setting heroes up.')
    CommandHero(1, -10980, 17293)
	CommandHero(2, -10980, 17293)
	CommandHero(3, -10980, 17293)
	CommandHero(4, -10980, 17293)
	CommandHero(5, -10980, 17293)
    CommandHero(6, -10980, 17293)
	CommandHero(7, -10980, 17293)
    MoveTo(-10980, 17293)
	; Disable Hero 6 skills here
	; disable all hero heals, movement, and life spirits
    For $i = 1 to 8
        DisableAllHeroSkills($i)
    Next
    Info('Getting into position to gate glitch inside.')
	CommandHero(6, -13413, 17171)
	MoveTo(-13400, 17378, 0)
    ;MoveTo(-13550, 17190, 0)

    ;If HallOfJudgementGateGlitchIn() == $SUCCESS Then Return $PAUSE
    If DhuumReturnPause() == $SUCCESS Then Return $Pause
    
    MoveTo(-13968, 17195, 0)
    Info('Rezzing heroes and setting up inside boss room.')
    CancelAll()
    CancelAllHeroes()
    CommandAll(-12832, 17280)
    EnableHeroSkillSlot(1, 8) ; Update this later with variable for correct hero and slot
    UseHeroSkill(1, 8, 6) ; Update this later with hero slots and rez skill slot
    RandomSleep(5000)
    MoveTo(-16331, 17430)
    Local $Dhuum = GetNearestNPCToCoords(-16331, 17430)
    UseSkillEx($UNDERWORLD_RECALL, $Dhuum)
    MoveTo(-17593, 17528)
    ;While heroes 1-7 are  not within earshot do this:
    CommandAll(-10980, 17293)
    RandomSleep(5000)
    CancelAll()
    RandomSleep(5000)

    Info('Setting heroes up.')
    CommandHero(1, -16120, 17285)
    CommandHero(2, -17623, 17380)
    CommandHero(3, -17623, 17380)
    CommandHero(4, -17623, 17380)
    CommandHero(5, -17623, 17380)
    CommandHero(6, -13456, 17378)
    CommandHero(7, -17623, 17380)
    Sleep(2000)
    Info('Getting into position to gate glitch inside.')
    MoveTo(-13456, 17171, 0)
	
    ;If HallOfJudgementGateGlitchOut() == $SUCCESS Then Return $PAUSE
    If DhuumReturnPause() == $SUCCESS Then Return $Pause

    DhuumStart()
    If DhuumFight() == $SUCCESS Then Return $Pause

    Return IsPlayerOrPartyAlive() ? $SUCCESS : $FAIL
EndFunc


Func SacAuraOfLichHeroDev($heroSlot, $spiritLightSlot, $auraOfLichSlot)
    UseHeroSkill($heroSlot, $spiritLightSlot, GetMyAgent())
    UseHeroSkill($heroSlot, $spiritLightSlot, GetMyAgent())
    UseHeroSkill($heroSlot, $spiritLightSlot, GetMyAgent())
    If Not $auraOfLichSlot == 0 Then
        Sleep(5000)
        UseHeroSkill($heroSlot, $auraOfLichSlot)
    EndIF
    ; Sac Hero
    While Not IsHeroDead($heroSlot)
        While Not IsRecharged($heroSlot, $spiritLightSlot)
            Sleep(1000)
        WEnd
        UseHeroSkill($heroSlot, $spiritLightSlot, GetMyAgent())
    WEnd
EndFunc

Func SacBiPHeroDev($heroSlot, $biPSlot)
    ; Sac Hero
    While Not IsHeroDead($heroSlot)
        While Not IsRecharged($heroSlot, $biPSlot)
            Sleep(1000)
        WEnd
        UseHeroSkill($heroSlot, $biPSlot, GetMyAgent())
    WEnd
EndFunc


Func DhuumReturnPause()
    Return IsPlayerOrPartyAlive() ? $SUCCESS : $FAIL
EndFunc

Func HallOfJudgementGateGlitchIn()
    Info('Setting up to attempt gate glitch.')
    Local $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
    While Not IsAgentInRange(GetMyAgent(), -13550, 17190, 10)
        $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
        If Not $foes Then
            If IsHeroDead(6) Then
                Info('Rezzing Saccer to try glitch again.')
                CancelHero(1)
                CancelHero(6)
                EnableHeroSkillSlot(1, 8) ; Update this later with variable for correct hero and slot
                UseHeroSkill(1, 8, 6) ; Update this later with hero slots and rez skill slot
                CommandHero(1, -12832, 17280)
                CommandHero(6, -12832, 17280)
                MoveTo(-13400, 17378, 0)
                ;MoveTo(-13550, 17190, 0)
            EndIf
            CancelHero(1)
            CancelHero(6)
            CommandHero(1, -10980, 17293)
            CommandHero(6, -13413, 17171)
            RandomSleep(1000)
            SacAuraOfLichHeroDev(6, 6, 1) ; Update this later with variable for correct hero, spirit light, and aotl slots
            $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
        Else
            MoveTo(-13968, 17195, 0)
            MoveForward(True)
            Sleep(2500)
            MoveForward(False)
            MoveTo(-13968, 17195, 0)
            $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
        EndIf
        $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
    WEnd
    Info('Successfully gate glitched!')
    Return IsPlayerOrPartyAlive() ? $SUCCESS : $FAIL
EndFunc


Func HallOfJudgementGateGlitchOut()
    Info('Setting up to attempt gate glitch.')
    Local $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
    While Not IsAgentInRange(GetMyAgent(), -13396, 17370, 10)
        $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
        If Not $foes Then
            If IsHeroDead(6) Then
                Info('Rezzing Saccer to try glitch again.')
                CancelHero(1)
                CancelHero(6)
                EnableHeroSkillSlot(1, 8) ; Update this later with variable for correct hero and slot
                UseHeroSkill(1, 8, 6) ; Update this later with hero slots and rez skill slot
                CommandHero(1, -14160, 17280)
                CommandHero(6, -13456, 17378)
                MoveTo(-13400, 17378, 0)
                ;MoveTo(-13550, 17190, 0)
            EndIf
            CancelHero(1)
            CancelHero(6)
            CommandHero(1, -16120, 17285)
            CommandHero(6, -13456, 17378)
            RandomSleep(1000)
            SacAuraOfLichHeroDev(6, 6, 1) ; Update this later with variable for correct hero, spirit light, and aotl slots
            $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
        Else
            MoveTo(-13396, 17370, 0)
            MoveForward(True)
            Sleep(2500)
            MoveForward(False)
            MoveTo(-13396, 17370, 0)

            $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
        EndIf
        $foes = GetFoesInRangeOfAgent(GetMyAgent(), $RANGE_EARSHOT)
    WEnd
    Info('Successfully gate glitched!')
    Return IsPlayerOrPartyAlive() ? $SUCCESS : $FAIL
EndFunc


Func DhuumFight()
    Info('Fight Time')
    Info('Saccing AotL and BiP Healers')
    SacBiPHeroDev(7, 1)
    SacAuraOfLichHeroDev(6, 6, 0)
    For $i = 1 to 8
        EnableHeroSkillSlot($i, $i)
    Next
    DisableAllHeroSkills(6)
    DisableAllHeroSkills(7)
    EnableHeroSkillSlot(6, 1)
    EnableHeroSkillSlot(7, 1)

    While IsPlayerOrPartyAlive()
		If IsQuestReward($ID_QUEST_THE_NIGHTMAN_COMETH) Then
			Info('Quest Successful: ' & $QUEST_NAMES_FROM_IDS[$ID_QUEST_THE_NIGHTMAN_COMETH])
			ExitLoop
		Else
			KillFoesInArea()
		EndIf
	WEnd
	If Not IsPlayerOrPartyAlive() Then
		Info('Quest Failed: ' & $QUEST_NAMES_FROM_IDS[$ID_QUEST_THE_NIGHTMAN_COMETH])
		Return $FAIL
	EndIf
    Info('Successfully Kill Dhuum!')
    Info('Going to the chest spot')
    MoveTo(-14528, 17267)
    RandomSleep(12000)
    Info('Looting Chest.')
    TargetNearestItem()
	ActionInteract()
	Sleep(2500)
	PickUpItems()
    MoveTo(-15708, 17348)
    Local $King_Frozenwind = GetNearestNPCToCoords(-15708, 17348)
    GoToNPC($King_Frozenwind)
    TakeQuestReward($King_Frozenwind, $ID_QUEST_THE_NIGHTMAN_COMETH, 0x846907)

    Return IsPlayerOrPartyAlive() ? $SUCCESS : $FAIL
EndFunc
