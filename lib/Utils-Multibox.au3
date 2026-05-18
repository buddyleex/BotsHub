#CS ===========================================================================
; Author: BuddyLeeX
; Copyright 2026
;
; Multibox shared memory communication library for BotsHub.
; Provides cross-account state sharing, messaging, event broadcasting,
; and in-game debug logging via the emotes channel.
;
#CE ===========================================================================

#include-once
#include <WinAPI.au3>
#include <WinAPIMem.au3>

#include 'Utils-Shared_Memory.au3'
#include 'Utils-Console.au3'
#include 'GWA2.au3'

; ==================== CONSTANTS ====================

Global Const $MAX_MULTIBOX_SLOTS = 10
Global Const $INBOX_MESSAGE_COUNT = 8
Global Const $STALE_THRESHOLD = 15000

; Shared memory block names
Global Const $ACCOUNT_STATE_BLOCK = 'Local\BotsHub_AccountState'
Global Const $INBOX_BLOCK_PREFIX = 'Local\BotsHub_Inbox_'

; Command type enum (for inbox messages)
Global Const $CMD_NONE = 0
Global Const $CMD_FOLLOW_LEADER = 1
Global Const $CMD_ATTACK_TARGET = 2
Global Const $CMD_USE_SKILL = 3
Global Const $CMD_MOVE_TO = 4
Global Const $CMD_STOP = 5
Global Const $CMD_RESURRECT = 6
Global Const $CMD_PICK_UP_LOOT = 7
Global Const $CMD_TRAVEL_TO_MAP = 8
Global Const $CMD_INVITE_TO_PARTY = 9
Global Const $CMD_INVITE_ALL_ACCOUNTS = 10
Global Const $CMD_ACCEPT_INVITE = 11
Global Const $CMD_TRAVEL_TO_GH = 12
Global Const $CMD_START_FARM = 13
Global Const $CMD_SHUTDOWN = 14
Global Const $CMD_CUSTOM = 99

; Debug logger sender name
Global Const $MB_DEBUG_SENDER = 'BHub'

; When True, bot behavior functions write verbose status to the in-game Bhub console.
; DO NOT enable inside ExecuteMultiboxCommand — WriteChat uses the GW command queue.
; Safe to use in main-loop bot functions (FollowerTick, FightFunctions, etc.).
Global $mb_verbose_log = False

; Farm name received via CMD_START_FARM; BotHubLoop activates it on the next tick.
Global $mb_pending_farm = ''

; Set True by OpenMultiboxSharedMemory; BotHubLoop emits the join chat message on its first tick
; (WriteChat crashes if called before GWA2 labels are resolved by the assembly scanner).
Global $mb_join_msg_pending = False

; ==================== STRUCT TEMPLATES ====================

Global Const $ACCOUNT_STATE_SLOT_TEMPLATE = _
	'byte slaveIndex;		byte active;			wchar characterName[20];' & _
	'dword agentID;			float posX;				float posY;				float rotation;' & _
	'float healthPercent;	dword maxHealth;		float energyPercent;	dword maxEnergy;' & _
	'dword effects;			dword modelState;		short currentSkill;		dword targetAgentID;' & _
	'byte primary;			byte secondary;			byte level;				byte isDead;' & _
	'dword mapID;			dword lastUpdated'

Global Const $INBOX_MESSAGE_TEMPLATE = _
	'byte active;			byte senderIndex;		dword command;' & _
	'float param1;			float param2;			float param3;			float param4;' & _
	'wchar extraData[64];	dword timestamp'

; ==================== GLOBAL STATE ====================

; DllStruct arrays for account state slots (one struct per slot, overlaid on shared memory)
Global $mb_state_structs[$MAX_MULTIBOX_SLOTS]
; DllStruct arrays for own inbox messages
Global $mb_inbox_structs[$INBOX_MESSAGE_COUNT]
; Map: slaveIndex -> array of DllStructs for writing to OTHER accounts' inboxes
Global $mb_outbox_structs[]
; This process's slave index
Global $mb_my_slot = -1
; Total known slaves
Global $mb_total_slaves = 0
; Handle tracking for cleanup
Global $mb_account_state_handle = 0
Global $mb_account_state_base = 0
Global $mb_inbox_handles[]
Global $mb_inbox_bases[]
Global $mb_failed_outbox_slots[] ; Track slots we failed to open so we can retry


; ==================== CREATION (Master calls these) ====================

Func CreateMultiboxAccountStateBlock()
	Local $slotSize = DllStructGetSize(DllStructCreate($ACCOUNT_STATE_SLOT_TEMPLATE))
	Local $totalSize = $slotSize * $MAX_MULTIBOX_SLOTS

	Local $handle = SafeDllCall15($kernel_handle, 'handle', 'CreateFileMappingW', _
		'handle', -1, _
		'ptr', 0, _
		'dword', $PAGE_READWRITE, _
		'dword', 0, _
		'dword', $totalSize, _
		'wstr', $ACCOUNT_STATE_BLOCK)
	If @error Or $handle[0] = 0 Then
		Error('Failed to create account state shared memory block.')
		Return False
	EndIf
	$mb_account_state_handle = $handle[0]

	Local $address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'dword', 0, _
		'dword', 0, _
		'dword', $totalSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Error('Failed to map account state shared memory.')
		Return False
	EndIf
	$mb_account_state_base = $address[0]

	; Create DllStruct overlays for each slot
	For $i = 0 To $MAX_MULTIBOX_SLOTS - 1
		$mb_state_structs[$i] = DllStructCreate($ACCOUNT_STATE_SLOT_TEMPLATE, $address[0] + ($i * $slotSize))
		; Initialize slot as inactive
		DllStructSetData($mb_state_structs[$i], 'active', 0)
	Next

	Info('Created multibox account state block (' & $totalSize & ' bytes, ' & $MAX_MULTIBOX_SLOTS & ' slots)')
	Return True
EndFunc


Func CreateMultiboxInboxBlock($slaveIndex)
	Local $msgSize = DllStructGetSize(DllStructCreate($INBOX_MESSAGE_TEMPLATE))
	Local $totalSize = $msgSize * $INBOX_MESSAGE_COUNT
	Local $memName = $INBOX_BLOCK_PREFIX & $slaveIndex

	Local $handle = SafeDllCall15($kernel_handle, 'handle', 'CreateFileMappingW', _
		'handle', -1, _
		'ptr', 0, _
		'dword', $PAGE_READWRITE, _
		'dword', 0, _
		'dword', $totalSize, _
		'wstr', $memName)
	If @error Or $handle[0] = 0 Then
		Error('Failed to create inbox block for slave ' & $slaveIndex)
		Return False
	EndIf

	Local $address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'dword', 0, _
		'dword', 0, _
		'dword', $totalSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Error('Failed to map inbox block for slave ' & $slaveIndex)
		Return False
	EndIf

	; Initialize all message slots as inactive
	Local $inboxStructs[$INBOX_MESSAGE_COUNT]
	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		$inboxStructs[$i] = DllStructCreate($INBOX_MESSAGE_TEMPLATE, $address[0] + ($i * $msgSize))
		DllStructSetData($inboxStructs[$i], 'active', 0)
	Next

	; Store struct array so the master can send messages to this slave
	$mb_outbox_structs[$slaveIndex] = $inboxStructs

	; Store handle for cleanup (master needs to track these)
	$sharedMemoryHandlesMap[$memName] = $handle[0]
	$mb_inbox_handles[$memName] = $handle[0]
	$mb_inbox_bases[$memName] = $address[0]

	Info('Created multibox inbox block for slave ' & $slaveIndex & ' (' & $totalSize & ' bytes, ' & $INBOX_MESSAGE_COUNT & ' slots)')
	Return True
EndFunc


; ==================== OPENING (Slave calls this) ====================

Func OpenMultiboxSharedMemory($slaveIndex, $totalSlaves)
	$mb_my_slot = $slaveIndex
	$mb_total_slaves = $totalSlaves
	_MBFileLog('OpenMultiboxSharedMemory: slot=' & $slaveIndex & ' totalSlaves=' & $totalSlaves)

	; --- Open Account State Block ---
	Local $slotSize = DllStructGetSize(DllStructCreate($ACCOUNT_STATE_SLOT_TEMPLATE))
	Local $stateSize = $slotSize * $MAX_MULTIBOX_SLOTS

	Local $handle = SafeDllCall9($kernel_handle, 'handle', 'OpenFileMappingW', _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'bool', False, _
		'wstr', $ACCOUNT_STATE_BLOCK)
	If @error Or $handle[0] = 0 Then
		_MBFileLog('FAIL: open account state block')
		Error('Failed to open account state shared memory block.')
		Return False
	EndIf
	$mb_account_state_handle = $handle[0]

	Local $address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'dword', 0, _
		'dword', 0, _
		'dword', $stateSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Error('Failed to map account state shared memory.')
		Return False
	EndIf
	$mb_account_state_base = $address[0]

	For $i = 0 To $MAX_MULTIBOX_SLOTS - 1
		$mb_state_structs[$i] = DllStructCreate($ACCOUNT_STATE_SLOT_TEMPLATE, $address[0] + ($i * $slotSize))
	Next

	; --- Open Own Inbox ---
	Local $msgSize = DllStructGetSize(DllStructCreate($INBOX_MESSAGE_TEMPLATE))
	Local $inboxSize = $msgSize * $INBOX_MESSAGE_COUNT
	Local $myInboxName = $INBOX_BLOCK_PREFIX & $slaveIndex

	$handle = SafeDllCall9($kernel_handle, 'handle', 'OpenFileMappingW', _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'bool', False, _
		'wstr', $myInboxName)
	If @error Or $handle[0] = 0 Then
		_MBFileLog('FAIL: open own inbox ' & $myInboxName)
		Error('Failed to open own inbox shared memory block.')
		Return False
	EndIf
	$mb_inbox_handles[$myInboxName] = $handle[0]

	$address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'dword', 0, _
		'dword', 0, _
		'dword', $inboxSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Error('Failed to map own inbox shared memory.')
		Return False
	EndIf
	$mb_inbox_bases[$myInboxName] = $address[0]

	Local $staleCount = 0
	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		$mb_inbox_structs[$i] = DllStructCreate($INBOX_MESSAGE_TEMPLATE, $address[0] + ($i * $msgSize))
		If DllStructGetData($mb_inbox_structs[$i], 'active') <> 0 Then
			_MBFileLog('WARNING: stale inbox message at slot ' & $i & ' cmd=' & DllStructGetData($mb_inbox_structs[$i], 'cmd') & ' — clearing')
			$staleCount += 1
		EndIf
		DllStructSetData($mb_inbox_structs[$i], 'active', 0)
	Next
	If $staleCount > 0 Then
		_MBFileLog('Cleared own inbox (' & $INBOX_MESSAGE_COUNT & ' slots zeroed, ' & $staleCount & ' stale found)')
	Else
		_MBFileLog('Cleared own inbox (' & $INBOX_MESSAGE_COUNT & ' slots zeroed)')
	EndIf

	; --- Open Other Accounts' Inboxes (for sending messages to them) ---
	For $s = 0 To $totalSlaves - 1
		If $s = $slaveIndex Then ContinueLoop
		Local $otherInboxName = $INBOX_BLOCK_PREFIX & $s

		$handle = SafeDllCall9($kernel_handle, 'handle', 'OpenFileMappingW', _
			'dword', $FILE_MAP_WRITE, _
			'bool', False, _
			'wstr', $otherInboxName)
		If @error Or $handle[0] = 0 Then
			Warn('Could not open inbox for slave ' & $s & ' (may not be started yet)')
			ContinueLoop
		EndIf
		$mb_inbox_handles[$otherInboxName] = $handle[0]

		$address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
			'handle', $handle[0], _
			'dword', $FILE_MAP_WRITE, _
			'dword', 0, _
			'dword', 0, _
			'dword', $inboxSize)
		If @error Or $address[0] = 0 Then
			SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
			Warn('Could not map inbox for slave ' & $s)
			ContinueLoop
		EndIf
		$mb_inbox_bases[$otherInboxName] = $address[0]

		; Create struct array for this outbox
		Local $outboxStructs[$INBOX_MESSAGE_COUNT]
		For $i = 0 To $INBOX_MESSAGE_COUNT - 1
			$outboxStructs[$i] = DllStructCreate($INBOX_MESSAGE_TEMPLATE, $address[0] + ($i * $msgSize))
		Next
		$mb_outbox_structs[$s] = $outboxStructs
	Next

	_MBFileLog('SUCCESS: Opened all multibox shared memory for slot ' & $slaveIndex)
	WriteChat('Slot ' & $slaveIndex & ' joined SHM (' & $totalSlaves & ' total)', 'Bhub', 6)
	SetEmoteLog('EmoteLog')
	Return True
EndFunc


; ==================== STATE PUBLISHING ====================

Func PublishAccountState()
	If $mb_my_slot < 0 Or $mb_my_slot >= $MAX_MULTIBOX_SLOTS Then Return

	Local $me = GetMyAgent()
	If $me = 0 Or $me = Null Then Return

	Local $slot = $mb_state_structs[$mb_my_slot]

	DllStructSetData($slot, 'slaveIndex', $mb_my_slot)
	DllStructSetData($slot, 'active', 1)
	DllStructSetData($slot, 'characterName', $character_name)
	DllStructSetData($slot, 'agentID', DllStructGetData($me, 'ID'))
	DllStructSetData($slot, 'posX', DllStructGetData($me, 'X'))
	DllStructSetData($slot, 'posY', DllStructGetData($me, 'Y'))
	DllStructSetData($slot, 'rotation', DllStructGetData($me, 'Rotation'))
	DllStructSetData($slot, 'healthPercent', DllStructGetData($me, 'HealthPercent'))
	DllStructSetData($slot, 'maxHealth', DllStructGetData($me, 'MaxHealth'))
	DllStructSetData($slot, 'energyPercent', DllStructGetData($me, 'EnergyPercent'))
	DllStructSetData($slot, 'maxEnergy', DllStructGetData($me, 'MaxEnergy'))
	DllStructSetData($slot, 'effects', DllStructGetData($me, 'Effects'))
	DllStructSetData($slot, 'modelState', DllStructGetData($me, 'ModelState'))
	DllStructSetData($slot, 'currentSkill', DllStructGetData($me, 'Skill'))
	DllStructSetData($slot, 'targetAgentID', DllStructGetData($me, 'Owner'))
	DllStructSetData($slot, 'primary', DllStructGetData($me, 'Primary'))
	DllStructSetData($slot, 'secondary', DllStructGetData($me, 'Secondary'))
	DllStructSetData($slot, 'level', DllStructGetData($me, 'Level'))

	Local $effects = DllStructGetData($me, 'Effects')
	DllStructSetData($slot, 'isDead', (BitAND($effects, 0x0010) > 0) ? 1 : 0)

	DllStructSetData($slot, 'mapID', GetMapID())

	; GetTickCount for staleness detection
	Local $tick = DllCall('kernel32.dll', 'dword', 'GetTickCount')
	If Not @error Then DllStructSetData($slot, 'lastUpdated', $tick[0])
EndFunc


; ==================== STATE READING ====================

Func ReadAccountState($slaveIndex)
	If $slaveIndex < 0 Or $slaveIndex >= $MAX_MULTIBOX_SLOTS Then Return Null

	Local $slot = $mb_state_structs[$slaveIndex]
	If DllStructGetData($slot, 'active') = 0 Then Return Null

	; Staleness check
	Local $tick = DllCall('kernel32.dll', 'dword', 'GetTickCount')
	If Not @error Then
		Local $lastUpdated = DllStructGetData($slot, 'lastUpdated')
		If ($tick[0] - $lastUpdated) > $STALE_THRESHOLD Then Return Null
	EndIf

	Local $state[]
	$state['slaveIndex'] = DllStructGetData($slot, 'slaveIndex')
	$state['active'] = DllStructGetData($slot, 'active')
	$state['characterName'] = DllStructGetData($slot, 'characterName')
	$state['agentID'] = DllStructGetData($slot, 'agentID')
	$state['posX'] = DllStructGetData($slot, 'posX')
	$state['posY'] = DllStructGetData($slot, 'posY')
	$state['rotation'] = DllStructGetData($slot, 'rotation')
	$state['healthPercent'] = DllStructGetData($slot, 'healthPercent')
	$state['maxHealth'] = DllStructGetData($slot, 'maxHealth')
	$state['energyPercent'] = DllStructGetData($slot, 'energyPercent')
	$state['maxEnergy'] = DllStructGetData($slot, 'maxEnergy')
	$state['effects'] = DllStructGetData($slot, 'effects')
	$state['modelState'] = DllStructGetData($slot, 'modelState')
	$state['currentSkill'] = DllStructGetData($slot, 'currentSkill')
	$state['targetAgentID'] = DllStructGetData($slot, 'targetAgentID')
	$state['primary'] = DllStructGetData($slot, 'primary')
	$state['secondary'] = DllStructGetData($slot, 'secondary')
	$state['level'] = DllStructGetData($slot, 'level')
	$state['isDead'] = DllStructGetData($slot, 'isDead')
	$state['mapID'] = DllStructGetData($slot, 'mapID')
	$state['lastUpdated'] = DllStructGetData($slot, 'lastUpdated')
	Return $state
EndFunc


Func GetAllActiveAccountStates()
	Local $results[0]
	For $i = 0 To $MAX_MULTIBOX_SLOTS - 1
		Local $state = ReadAccountState($i)
		If $state <> Null Then
			ReDim $results[UBound($results) + 1]
			$results[UBound($results) - 1] = $state
		EndIf
	Next
	Return $results
EndFunc


Func IsSlotActive($slaveIndex)
	If $slaveIndex < 0 Or $slaveIndex >= $MAX_MULTIBOX_SLOTS Then Return False
	Local $slot = $mb_state_structs[$slaveIndex]
	If DllStructGetData($slot, 'active') = 0 Then Return False

	Local $tick = DllCall('kernel32.dll', 'dword', 'GetTickCount')
	If Not @error Then
		Local $lastUpdated = DllStructGetData($slot, 'lastUpdated')
		If ($tick[0] - $lastUpdated) > $STALE_THRESHOLD Then Return False
	EndIf
	Return True
EndFunc


Func GetAccountPosition($slaveIndex)
	If Not IsSlotActive($slaveIndex) Then Return Null
	Local $slot = $mb_state_structs[$slaveIndex]
	Local $pos[2]
	$pos[0] = DllStructGetData($slot, 'posX')
	$pos[1] = DllStructGetData($slot, 'posY')
	Return $pos
EndFunc


Func IsAccountDead($slaveIndex)
	If Not IsSlotActive($slaveIndex) Then Return True
	Return DllStructGetData($mb_state_structs[$slaveIndex], 'isDead') = 1
EndFunc


Func GetAccountTarget($slaveIndex)
	If Not IsSlotActive($slaveIndex) Then Return 0
	Return DllStructGetData($mb_state_structs[$slaveIndex], 'targetAgentID')
EndFunc


Func GetDistanceToAccount($slaveIndex)
	If $mb_my_slot < 0 Then Return -1
	Local $myPos = GetAccountPosition($mb_my_slot)
	Local $otherPos = GetAccountPosition($slaveIndex)
	If $myPos = Null Or $otherPos = Null Then Return -1
	Return Sqrt(($myPos[0] - $otherPos[0]) ^ 2 + ($myPos[1] - $otherPos[1]) ^ 2)
EndFunc



; ==================== MESSAGING ====================

; Try to open an outbox connection to a slot that failed initially (on-demand retry)
Func _RetryOpenOutboxForSlot($slotIndex)
	Local $msgSize = DllStructGetSize(DllStructCreate($INBOX_MESSAGE_TEMPLATE))
	Local $inboxSize = $msgSize * $INBOX_MESSAGE_COUNT
	Local $otherInboxName = $INBOX_BLOCK_PREFIX & $slotIndex

	Local $handle = SafeDllCall9($kernel_handle, 'handle', 'OpenFileMappingW', _
		'dword', $FILE_MAP_WRITE, _
		'bool', False, _
		'wstr', $otherInboxName)
	If @error Or $handle[0] = 0 Then
		Return False
	EndIf
	$mb_inbox_handles[$otherInboxName] = $handle[0]

	Local $address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', $FILE_MAP_WRITE, _
		'dword', 0, _
		'dword', 0, _
		'dword', $inboxSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Return False
	EndIf
	$mb_inbox_bases[$otherInboxName] = $address[0]

	Local $outboxStructs[$INBOX_MESSAGE_COUNT]
	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		$outboxStructs[$i] = DllStructCreate($INBOX_MESSAGE_TEMPLATE, $address[0] + ($i * $msgSize))
	Next
	$mb_outbox_structs[$slotIndex] = $outboxStructs
	_MBFileLog('_RetryOpenOutboxForSlot: successfully opened outbox for slot ' & $slotIndex)
	Return True
EndFunc

Func SendMultiboxMessage($targetSlaveIndex, $command, $param1 = 0, $param2 = 0, $param3 = 0, $param4 = 0, $extraData = '')
	If $mb_my_slot >= 0 And $targetSlaveIndex = $mb_my_slot Then Return False
	If Not MapExists($mb_outbox_structs, $targetSlaveIndex) Then
		; Try to open the outbox for this slot (it may have been created after we started)
		If Not _RetryOpenOutboxForSlot($targetSlaveIndex) Then
			Warn('No outbox connection to slave ' & $targetSlaveIndex)
			Return False
		EndIf
	EndIf

	Local $outbox = $mb_outbox_structs[$targetSlaveIndex]

	; Find first empty slot
	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		If DllStructGetData($outbox[$i], 'active') = 0 Then
			; Write all data fields before setting active flag
			DllStructSetData($outbox[$i], 'senderIndex', ($mb_my_slot >= 0) ? $mb_my_slot : 255)
			DllStructSetData($outbox[$i], 'command', $command)
			DllStructSetData($outbox[$i], 'param1', $param1)
			DllStructSetData($outbox[$i], 'param2', $param2)
			DllStructSetData($outbox[$i], 'param3', $param3)
			DllStructSetData($outbox[$i], 'param4', $param4)
			DllStructSetData($outbox[$i], 'extraData', $extraData)

			Local $tick = DllCall('kernel32.dll', 'dword', 'GetTickCount')
			If Not @error Then DllStructSetData($outbox[$i], 'timestamp', $tick[0])

			; Set active last (signals to receiver that data is ready)
			DllStructSetData($outbox[$i], 'active', 1)

			MBDebug('Sent cmd ' & $command & ' to slave ' & $targetSlaveIndex)
			Return True
		EndIf
	Next

	MBWarn('Inbox full for slave ' & $targetSlaveIndex)
	Return False
EndFunc


Func ReceiveMultiboxMessages()
	Local $messages[0]
	Local $now = DllCall('kernel32.dll', 'dword', 'GetTickCount')
	Local $currentTick = (Not @error) ? $now[0] : 0

	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		If DllStructGetData($mb_inbox_structs[$i], 'active') = 1 Then
			Local $msgTimestamp = DllStructGetData($mb_inbox_structs[$i], 'timestamp')

			; Discard messages older than STALE_THRESHOLD (stale from previous session)
			If $currentTick > 0 And $msgTimestamp > 0 And ($currentTick - $msgTimestamp) > $STALE_THRESHOLD Then
				_MBFileLog('Discarding stale message in slot ' & $i & ': cmd=' & DllStructGetData($mb_inbox_structs[$i], 'command') & ' age=' & ($currentTick - $msgTimestamp) & 'ms')
				DllStructSetData($mb_inbox_structs[$i], 'active', 0)
				ContinueLoop
			EndIf

			Local $msg[]
			$msg['index'] = $i
			$msg['senderIndex'] = DllStructGetData($mb_inbox_structs[$i], 'senderIndex')
			$msg['command'] = DllStructGetData($mb_inbox_structs[$i], 'command')
			$msg['param1'] = DllStructGetData($mb_inbox_structs[$i], 'param1')
			$msg['param2'] = DllStructGetData($mb_inbox_structs[$i], 'param2')
			$msg['param3'] = DllStructGetData($mb_inbox_structs[$i], 'param3')
			$msg['param4'] = DllStructGetData($mb_inbox_structs[$i], 'param4')
			$msg['extraData'] = DllStructGetData($mb_inbox_structs[$i], 'extraData')
			$msg['timestamp'] = DllStructGetData($mb_inbox_structs[$i], 'timestamp')

			; Clear the slot after reading
			DllStructSetData($mb_inbox_structs[$i], 'active', 0)

			ReDim $messages[UBound($messages) + 1]
			$messages[UBound($messages) - 1] = $msg
		EndIf
	Next
	Return $messages
EndFunc


Func PeekNextMessage()
	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		If DllStructGetData($mb_inbox_structs[$i], 'active') = 1 Then
			Local $msg[]
			$msg['index'] = $i
			$msg['senderIndex'] = DllStructGetData($mb_inbox_structs[$i], 'senderIndex')
			$msg['command'] = DllStructGetData($mb_inbox_structs[$i], 'command')
			$msg['param1'] = DllStructGetData($mb_inbox_structs[$i], 'param1')
			$msg['param2'] = DllStructGetData($mb_inbox_structs[$i], 'param2')
			$msg['param3'] = DllStructGetData($mb_inbox_structs[$i], 'param3')
			$msg['param4'] = DllStructGetData($mb_inbox_structs[$i], 'param4')
			$msg['extraData'] = DllStructGetData($mb_inbox_structs[$i], 'extraData')
			$msg['timestamp'] = DllStructGetData($mb_inbox_structs[$i], 'timestamp')
			Return $msg
		EndIf
	Next
	Return Null
EndFunc


Func AcknowledgeMessage($messageIndex)
	If $messageIndex >= 0 And $messageIndex < $INBOX_MESSAGE_COUNT Then
		DllStructSetData($mb_inbox_structs[$messageIndex], 'active', 0)
	EndIf
EndFunc


; ==================== EVENT LOG ====================


; ==================== DEBUG LOGGER ====================

Func EmoteLog($text, $level = $LVL_INFO)
	If $level < $LVL_INFO Then Return
	WriteChat(StringLeft($text, 100), $MB_DEBUG_SENDER, 6)
EndFunc

Func MultiboxLog($message, $level = 'INF')
	Local $formatted = '[' & $MB_DEBUG_SENDER & ':' & $level & '] ' & $message
	Switch $level
		Case 'DBG'
			Debug($formatted)
		Case 'INF'
			Info($formatted)
		Case 'WRN'
			Warn($formatted)
		Case 'ERR'
			Error($formatted)
	EndSwitch
EndFunc

Func MBDebug($msg)
	MultiboxLog($msg, 'DBG')
EndFunc

Func MBInfo($msg)
	MultiboxLog($msg, 'INF')
EndFunc

Func MBWarn($msg)
	MultiboxLog($msg, 'WRN')
EndFunc

Func MBError($msg)
	MultiboxLog($msg, 'ERR')
EndFunc

; Write to in-game Bhub console only when $mb_verbose_log = True.
; ONLY call from main-loop context (FollowerTick, FightFunctions, etc.), never from ExecuteMultiboxCommand.
Func MBChatLog($msg)
	If $mb_verbose_log Then WriteChat(StringLeft($msg, 100), $MB_DEBUG_SENDER, 6)
EndFunc


; ==================== CLEANUP ====================

Func CloseMultiboxSharedMemory()
	; Clear own slot
	If $mb_my_slot >= 0 And $mb_my_slot < $MAX_MULTIBOX_SLOTS Then
		DllStructSetData($mb_state_structs[$mb_my_slot], 'active', 0)
	EndIf

	; Unmap and close account state block
	If $mb_account_state_base <> 0 Then
		SafeDllCall5($kernel_handle, 'bool', 'UnmapViewOfFile', 'ptr', $mb_account_state_base)
		$mb_account_state_base = 0
	EndIf
	If $mb_account_state_handle <> 0 Then
		SafeDllCall5($kernel_handle, 'bool', 'CloseHandle', 'handle', $mb_account_state_handle)
		$mb_account_state_handle = 0
	EndIf

	; Close all inbox mappings
	For $key In MapKeys($mb_inbox_bases)
		SafeDllCall5($kernel_handle, 'bool', 'UnmapViewOfFile', 'ptr', $mb_inbox_bases[$key])
	Next
	For $key In MapKeys($mb_inbox_handles)
		SafeDllCall5($kernel_handle, 'bool', 'CloseHandle', 'handle', $mb_inbox_handles[$key])
	Next

	Info('Closed multibox shared memory for slot ' & $mb_my_slot)
EndFunc


; ==================== DIAGNOSTIC FILE LOG ====================

Func _MBFileLog($text)
	Local $logFile = @ScriptDir & '\logs\multibox_debug.log'
	Local $hFile = FileOpen($logFile, 1) ; append mode
	If $hFile <> -1 Then
		FileWriteLine($hFile, @YEAR & '-' & @MON & '-' & @MDAY & ' ' & @HOUR & ':' & @MIN & ':' & @SEC & ' [slot ' & $mb_my_slot & '] ' & $text)
		FileClose($hFile)
	EndIf
EndFunc


; ==================== DEFERRED COMMAND QUEUE ====================
; Game commands (Move, Attack, UseSkill, etc.) call Enqueue() -> WriteProcessMemory.
; When called from an AdlibRegister callback, these writes can silently fail because
; the game's command queue counter may be out of sync with AutoIt's local counter.
; Solution: the callback queues commands, and the main loop executes them.

Global Const $MAX_DEFERRED_COMMANDS = 8
Global $mb_deferred_commands[$MAX_DEFERRED_COMMANDS]
Global $mb_deferred_count = 0

Func QueueDeferredCommand($msg)
	If $mb_deferred_count >= $MAX_DEFERRED_COMMANDS Then
		MBWarn('Deferred command queue full, dropping oldest')
		; Shift everything left, dropping slot 0
		For $i = 0 To $MAX_DEFERRED_COMMANDS - 2
			$mb_deferred_commands[$i] = $mb_deferred_commands[$i + 1]
		Next
		$mb_deferred_count = $MAX_DEFERRED_COMMANDS - 1
	EndIf
	$mb_deferred_commands[$mb_deferred_count] = $msg
	$mb_deferred_count += 1
EndFunc


; Call this from the main bot loop (NOT from AdlibRegister)
Func ProcessDeferredCommands()
	While $mb_deferred_count > 0
		; Dequeue from the front before executing so any commands queued during
		; Sleep() inside a command handler land safely at the end of the queue.
		Local $nextMsg = $mb_deferred_commands[0]
		For $i = 0 To $mb_deferred_count - 2
			$mb_deferred_commands[$i] = $mb_deferred_commands[$i + 1]
		Next
		$mb_deferred_count -= 1
		$mb_deferred_commands[$mb_deferred_count] = Null

		If $nextMsg <> Null Then
			_MBFileLog('ProcessDeferredCommands: executing queued command')
			ExecuteMultiboxCommand($nextMsg)
		EndIf
	WEnd
EndFunc


; Re-read the game's queue counter to keep the local copy in sync
Func SyncQueueCounter()
	Local $gameCounter = MemoryRead(GetProcessHandle(), GetLabel('QueueCounter'))
	If @error Then
		_MBFileLog('SyncQueueCounter: MemoryRead failed (@error=' & @error & '), keeping local=' & $queue_counter)
		Return
	EndIf
	If $queue_counter <> $gameCounter Then
		_MBFileLog('SyncQueueCounter: RESYNC local=' & $queue_counter & ' -> game=' & $gameCounter)
		$queue_counter = $gameCounter
	Else
		_MBFileLog('SyncQueueCounter: in sync at ' & $queue_counter)
	EndIf
EndFunc


; ==================== MESSAGE HANDLING & CLEANUP ====================

Func ProcessInboxMessages()
	Local $messages = ReceiveMultiboxMessages()
	If UBound($messages) > 0 Then
		_MBFileLog('Received ' & UBound($messages) & ' message(s), deferring to main loop')
		Info('Received ' & UBound($messages) & ' message(s)')
	EndIf
	For $i = 0 To UBound($messages) - 1
		QueueDeferredCommand($messages[$i])
	Next
EndFunc


; Execute a multibox command (called from main loop context, not from AdlibRegister)
; IMPORTANT: Do NOT call MBInfo/MBWarn/MBError/MBDebug here — they call WriteChat()
; which advances $queue_counter and causes desync with the game's actual counter.
; Use _MBFileLog (file only) + Info/Warn (console only) for logging instead.
Func ExecuteMultiboxCommand($msg)
	Local $cmd = $msg['command']
	Local $sender = $msg['senderIndex']
	_MBFileLog('ExecuteMultiboxCommand: cmd=' & $cmd & ' sender=' & $sender & ' params=(' & $msg['param1'] & ', ' & $msg['param2'] & ', ' & $msg['param3'] & ', ' & $msg['param4'] & ')')

	Switch $cmd
		Case $CMD_FOLLOW_LEADER
			; Leader is always slot 0 — sender may be Manager (255), not a position source
			Local $leaderState = ReadAccountState(0)
			If $leaderState <> Null Then
				_MBFileLog('Following leader slot 0 (' & $leaderState['characterName'] & ')')
				Info('Following leader: ' & $leaderState['characterName'])
				SyncQueueCounter()
				Move($leaderState['posX'], $leaderState['posY'])
			Else
				_MBFileLog('CMD_FOLLOW_LEADER: slot 0 not active or stale')
				Info('Follow failed: leader (slot 0) not in shared memory')
			EndIf

		Case $CMD_ATTACK_TARGET
			Local $targetID = Int($msg['param1'])
			If $targetID > 0 Then
				_MBFileLog('Attacking target ' & $targetID & ' (from slave ' & $sender & ')')
				Info('Attacking target ' & $targetID & ' (from slave ' & $sender & ')')
				SyncQueueCounter()
				Attack(GetAgentByID($targetID))
			EndIf

		Case $CMD_USE_SKILL
			Local $skillSlot = Int($msg['param1'])
			Local $skillTarget = Int($msg['param2'])
			If $skillSlot > 0 Then
				_MBFileLog('Using skill ' & $skillSlot & ' on target ' & $skillTarget & ' (from slave ' & $sender & ')')
				Info('Using skill ' & $skillSlot & ' on target ' & $skillTarget & ' (from slave ' & $sender & ')')
				SyncQueueCounter()
				If $skillTarget > 0 Then
					UseSkillEx($skillSlot, GetAgentByID($skillTarget))
				Else
					UseSkillEx($skillSlot)
				EndIf
			EndIf

		Case $CMD_MOVE_TO
			_MBFileLog('Moving to (' & $msg['param1'] & ', ' & $msg['param2'] & ') (from slave ' & $sender & ')')
			Info('Moving to (' & $msg['param1'] & ', ' & $msg['param2'] & ') (from slave ' & $sender & ')')
			SyncQueueCounter()
			Move(Number($msg['param1']), Number($msg['param2']))

		Case $CMD_STOP
			_MBFileLog('Stop command from slave ' & $sender)
			Info('Stop command from slave ' & $sender)
			Local $me = GetMyAgent()
			If $me <> 0 And $me <> Null Then
				SyncQueueCounter()
				Move(DllStructGetData($me, 'X'), DllStructGetData($me, 'Y'))
			EndIf

		Case $CMD_TRAVEL_TO_MAP
			Local $mapID = Int($msg['param1'])
			_MBFileLog('Traveling to map ' & $mapID & ' (from slave ' & $sender & ')')
			Info('Traveling to map ' & $mapID & ' (from slave ' & $sender & ')')
			SyncQueueCounter()
			TravelToOutpost($mapID)

		Case $CMD_TRAVEL_TO_GH
			Local $currentMapID = GetMapID()
			If _ArraySearch($GUILDHALL_MAP_IDS, $currentMapID) = -1 Then
				_MBFileLog('Traveling to guild hall (from slave ' & $sender & ')')
				Info('Traveling to guild hall')
				SyncQueueCounter()
				TravelGuildHall()
			Else
				_MBFileLog('Already in guild hall (map ' & $currentMapID & '), skipping travel')
				Info('Already in guild hall, skipping travel')
			EndIf

		Case $CMD_RESURRECT
			_MBFileLog('Resurrect command from slave ' & $sender)
			Info('Resurrect command from slave ' & $sender)
			; No functions setup for this CMD yet

		Case $CMD_PICK_UP_LOOT
			_MBFileLog('Loot command from slave ' & $sender)
			Info('Loot command from slave ' & $sender)
			PickUpItems()

		Case $CMD_INVITE_TO_PARTY
			_MBFileLog('Party invite command from slave ' & $sender)
			Info('Party invite command from slave ' & $sender)
			; No functions setup for this CMD yet

		Case $CMD_INVITE_ALL_ACCOUNTS
			_MBFileLog('InviteAllAccounts: starting party formation')
			Info('Forming party: inviting all active accounts')
			; If already in a multi-player party, leave first to reset state
			If GetPartySize() > 1 Then
				_MBFileLog('InviteAllAccounts: already in party (size=' & GetPartySize() & '), leaving first')
				SyncQueueCounter()
				LeaveParty(False)
				Sleep(500)
			EndIf
			SyncQueueCounter()

			; Read leader party ID from party_obj[0x0]
			Local $invPH = GetProcessHandle()
			Local $invCtxOff[] = [0, 0x18, 0x4C]
			Local $invCtxResult = MemoryReadPtr($invPH, $base_address_ptr, $invCtxOff)
			Local $leaderPartyID = 0
			If Not @error And $invCtxResult[1] <> 0 Then
				Local $party_ctx = $invCtxResult[1]
				Local $party_obj = MemoryRead($invPH, $party_ctx + 0x54)
				If $party_obj <> 0 Then
					$leaderPartyID = MemoryRead($invPH, $party_obj + 0x0)
				EndIf
			EndIf
			_MBFileLog('InviteAllAccounts: leader party ID = ' & $leaderPartyID)
			If $leaderPartyID = 0 Then
				_MBFileLog('InviteAllAccounts: ERROR - party ID is 0, aborting')
				Info('ERROR: Could not read leader party ID')
				Return
			EndIf

			; Phase 1: send ALL invites before any accepts — GW1 silently rejects new invites
			; once an earlier accept completes and changes party state on the server.
			Local $pendingSlots[$MAX_MULTIBOX_SLOTS]
			Local $pendingCount = 0
			For $invSlot = 0 To $MAX_MULTIBOX_SLOTS - 1
				If $invSlot = $mb_my_slot Then ContinueLoop
				Local $invPeer = ReadAccountState($invSlot)
				If $invPeer = Null Or $invPeer['active'] = 0 Then ContinueLoop
				Local $invName = $invPeer['characterName']
				If $invName = '' Then ContinueLoop
				Local $invAgentID = $invPeer['agentID']
				If $invAgentID = 0 Then
					_MBFileLog('InviteAllAccounts: WARNING - agent ID 0 for slot ' & $invSlot & ', skipping')
					ContinueLoop
				EndIf
				Local $invAgent = GetAgentByID($invAgentID)
				Local $invPlayerNum = DllStructGetData($invAgent, 'LoginNumber')
				_MBFileLog('InviteAllAccounts: inviting ' & $invName & ' (slot ' & $invSlot & ') playerNum=' & $invPlayerNum)
				SendPacket(0x8, $HEADER_PARTY_INVITE_PLAYER, $invPlayerNum)
				$pendingSlots[$pendingCount] = $invSlot
				$pendingCount += 1
				Sleep(250)
			Next

			; Phase 2: wait for GW server to deliver all invites to clients before any accept
			; GW1 party invites route through the server; 1000ms gives enough margin
			_MBFileLog('InviteAllAccounts: ' & $pendingCount & ' invites sent, waiting for server delivery')
			Sleep(500)

			; Phase 3: signal all accepts
			For $i = 0 To $pendingCount - 1
				_MBFileLog('InviteAllAccounts: signalling accept to slot ' & $pendingSlots[$i] & ' with party ID ' & $leaderPartyID)
				SendMultiboxMessage($pendingSlots[$i], $CMD_ACCEPT_INVITE, $leaderPartyID)
				Sleep(250)
			Next
			_MBFileLog('InviteAllAccounts: all accept signals dispatched')
			Info('Party invites sent to all active accounts')

		Case $CMD_ACCEPT_INVITE
			Local $partyID = Int($msg['param1'])
			_MBFileLog('CMD_ACCEPT_INVITE: party ID ' & $partyID & ' from leader slot ' & $sender)
			Info('Auto-accepting party invite (ID ' & $partyID & ')')
			; Retry up to 3 times — GW server may not have delivered the invite to this client yet.
			; SyncQueueCounter must immediately precede SendPacket; sleeping between them risks counter desync.
			For $acAttempt = 1 To 3
				SyncQueueCounter()
				_MBFileLog('CMD_ACCEPT_INVITE: attempt ' & $acAttempt & ' sending accept for party ' & $partyID)
				SendPacket(0x8, $HEADER_PARTY_ACCEPT_INVITE, $partyID)
				_MBFileLog('CMD_ACCEPT_INVITE: accept packet queued (attempt ' & $acAttempt & ')')
				Sleep(1000)
				If GetPartySize() > 1 Then
					_MBFileLog('CMD_ACCEPT_INVITE: joined party successfully')
					ExitLoop
				EndIf
				If $acAttempt < 3 Then _MBFileLog('CMD_ACCEPT_INVITE: not in party, retrying...')
			Next

		Case $CMD_SHUTDOWN
			_MBFileLog('CMD_SHUTDOWN: leaving SHM gracefully')
			SyncQueueCounter()
			WriteChat('Slot ' & $mb_my_slot & ' leaving SHM', 'Bhub', 6)
			Sleep(150)
			Exit

		Case $CMD_START_FARM
			Local $farmName = $msg['extraData']
			_MBFileLog('CMD_START_FARM: farm=' & $farmName & ' from slave ' & $sender)
			Info('Activating farm: ' & $farmName)
			$mb_pending_farm = $farmName

		Case $CMD_CUSTOM
			_MBFileLog('Custom command from slave ' & $sender & ': ' & $msg['extraData'])
			Info('Custom command from slave ' & $sender & ': ' & $msg['extraData'])
			; No functions setup for this CMD yet

		Case Else
			_MBFileLog('Unknown multibox command: ' & $cmd & ' from slave ' & $sender)
			Warn('Unknown multibox command: ' & $cmd & ' from slave ' & $sender)
	EndSwitch
EndFunc


Func CleanupMultibox()
	AdlibUnRegister('PublishAccountState')
	AdlibUnRegister('ProcessInboxMessages')
	SyncQueueCounter()
	WriteChat('Slot ' & $mb_my_slot & ' leaving SHM', 'Bhub', 6)
	CloseMultiboxSharedMemory()
EndFunc
