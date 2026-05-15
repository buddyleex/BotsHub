#CS ===========================================================================
; Author: caustic-kronos (aka Kronos, Night, Svarog)
; Copyright 2026 caustic-kronos
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

#RequireAdmin
;#NoTrayIcon

Opt('MustDeclareVars', True)

#Region Includes
#include-once
#include 'lib/BotsHubManager-GUI.au3'
#include 'lib/GWA2_Assembly.au3'
#include 'lib/Utils-Console.au3'
#include 'lib/Utils-Shared_Memory.au3'
#include 'lib/Utils-Multibox.au3'
#EndRegion Includes


Global Const $STATE_IDLE = 0
Global Const $STATE_RUNNING = 1
Global Const $STATE_STOPPED = 2

; ---- GUI ----
Global Const $GUI_WIDTH = 500
Global Const $GUI_HEIGHT = 350

Global $master_heartbeat = 0
Global $slave_count = 0
Global $slave_character[10]
Global $slave_farm[10]
Global $slave_game_PID[10]
Global $slave_bot_PID[10]
Global $slave_heartbeat[10]
Global $slave_state[10]

LauncherMain()

Func LauncherMain()
	Local $gui = CreateBotsHubManagerGUI()
	CreateMasterSharedMemoryBlock()
	CreateMultiboxAccountStateBlock()
	CreateMultiboxEventLogBlock()
	WriteMasterBroadcast('state', $STATE_RUNNING)
	ScanAndUpdateGameClients()
	SelectClient(1)
	PopulateClientRows()
	AdlibRegister('UpdateMasterHeartbeat', 5000)
	OnAutoItExitRegister('CloseManager')
	While True
		UpdateInstancesUptime()
		Sleep(1000)
	WEnd
EndFunc


; Auto-populate a row for each detected game client
Func PopulateClientRows()
	Local $clientCount = $game_clients[0][0]
	If $clientCount = 0 Then
		Info('No game clients detected.')
		Return
	EndIf

	; First row was already created by CreateBotsHubManagerGUI, populate it
	; Additional rows need to be added
	For $i = 1 To $clientCount
		Local $charName = $game_clients[$i][3]
		If $i > 1 Then GuiAddRow()
		Local $rowId = $i - 1
		GUICtrlSetData($client_row[$rowId][$ROW_CHARACTER_INDEX], $charName)
	Next
	Info('Auto-populated ' & $clientCount & ' game client(s)')
EndFunc


Func CloseManager()
	AdlibUnregister('UpdateMasterHeartbeat')
	CloseSharedMemory($MASTER_BROADCAST)
	For $i = 0 To $slave_count - 1
		CloseSharedMemory($MASTER_TO_SLAVE & '_' & $i)
		CloseSharedMemory($SLAVE_TO_MASTER & '_' & $i)
		CloseSharedMemory($INBOX_BLOCK_PREFIX & $i)
	Next
	; Close multibox shared blocks (account state and event log handles managed by Utils-Multibox)
	CloseMultiboxSharedMemory()
EndFunc


Func StartBotInstance($character, $farm)
	Local $index = FindClientIndexByCharacterName($character)
	SelectClient($index)
	Local $pid = GetPID()
	Local $slaveIndex = $slave_count

	; Kill any leftover bot process from a previous Manager session
	; that might still be running for this game PID
	KillOrphanedBotProcesses($pid)

	$slave_count += 1
	$slave_character[$slaveIndex] = $character
	$slave_farm[$slaveIndex] = $farm
	$slave_game_PID[$slaveIndex] = $pid
	CreateSlaveSharedMemoryBlock($slaveIndex)
	CreateMultiboxInboxBlock($slaveIndex)

	Local $cmd = '"' & @AutoItExe & '" "' & @ScriptDir & '\BotsHub.au3" ' & $slaveIndex  & ' ' & $pid & ' "' & $character & '" "' & $farm & '" ' & $slave_count
	Info($cmd)
	$slave_bot_PID[$slaveIndex] = Run($cmd)
	Return $slaveIndex
EndFunc


Func StopBotInstance($slaveIndex)
	If ProcessExists($slave_bot_PID[$slaveIndex]) Then ProcessClose($slave_bot_PID[$slaveIndex])
EndFunc


; Kill any orphaned AutoIt processes that were started with the same game PID argument.
; This prevents old bot instances from racing with new ones on shared memory.
Func KillOrphanedBotProcesses($gamePID)
	Local $processList = ProcessList(@AutoItExe)
	If Not IsArray($processList) Or $processList[0][0] = 0 Then Return

	Local $gamePIDStr = String($gamePID)
	For $i = 1 To $processList[0][0]
		Local $botPID = $processList[$i][1]
		; Don't kill ourselves (the Manager)
		If $botPID = @AutoItPID Then ContinueLoop
		; Don't kill bot instances we already track
		Local $isTracked = False
		For $j = 0 To $slave_count - 1
			If $slave_bot_PID[$j] = $botPID Then
				$isTracked = True
				ExitLoop
			EndIf
		Next
		If $isTracked Then ContinueLoop

		; Check command line for this PID to see if it's a BotsHub instance for our game PID
		Local $cmdLine = _WinAPI_GetProcessCommandLine($botPID)
		If @error Or $cmdLine = '' Then ContinueLoop
		If StringInStr($cmdLine, 'BotsHub.au3') And StringInStr($cmdLine, ' ' & $gamePIDStr & ' ') Then
			Info('Killing orphaned bot process ' & $botPID & ' (game PID ' & $gamePIDStr & ')')
			ProcessClose($botPID)
			Sleep(500)
		EndIf
	Next
EndFunc


Func UpdateMasterHeartbeat()
	WriteMasterBroadcast('heartbeat', $master_heartbeat)
	$master_heartbeat += 1
EndFunc