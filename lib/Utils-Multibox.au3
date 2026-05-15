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
Global Const $EVENT_LOG_SIZE = 32
Global Const $STALE_THRESHOLD = 15000

; Shared memory block names
Global Const $ACCOUNT_STATE_BLOCK = 'Local\BotsHub_AccountState'
Global Const $INBOX_BLOCK_PREFIX = 'Local\BotsHub_Inbox_'
Global Const $EVENT_LOG_BLOCK = 'Local\BotsHub_EventLog'

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
Global Const $CMD_CUSTOM = 99

; Event type enum (for event log)
Global Const $EVT_NONE = 0
Global Const $EVT_SKILL_CAST = 1
Global Const $EVT_DEATH = 2
Global Const $EVT_KILL = 3
Global Const $EVT_RESURRECT = 4
Global Const $EVT_LOOT = 5
Global Const $EVT_MAP_CHANGE = 6
Global Const $EVT_LOW_HEALTH = 7
Global Const $EVT_PARTY_WIPE = 8

; Debug logger sender name
Global Const $MB_DEBUG_SENDER = 'BHub'

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

Global Const $EVENT_LOG_ENTRY_TEMPLATE = _
	'byte active;			byte slaveIndex;		dword eventType;' & _
	'dword targetAgentID;	short skillID;			dword timestamp'

Global Const $EVENT_LOG_HEADER_TEMPLATE = 'dword writeIndex'

; ==================== GLOBAL STATE ====================

; DllStruct arrays for account state slots (one struct per slot, overlaid on shared memory)
Global $mb_state_structs[$MAX_MULTIBOX_SLOTS]
; DllStruct arrays for own inbox messages
Global $mb_inbox_structs[$INBOX_MESSAGE_COUNT]
; Map: slaveIndex -> array of DllStructs for writing to OTHER accounts' inboxes
Global $mb_outbox_structs[]
; DllStruct array for event log entries
Global $mb_event_structs[$EVENT_LOG_SIZE]
; DllStruct for event log header (contains writeIndex)
Global $mb_event_header_struct = Null
; Read cursor for event log (this process's position)
Global $mb_event_read_cursor = 0
; This process's slave index
Global $mb_my_slot = -1
; Total known slaves
Global $mb_total_slaves = 0
; Handle tracking for cleanup
Global $mb_account_state_handle = 0
Global $mb_account_state_base = 0
Global $mb_event_log_handle = 0
Global $mb_event_log_base = 0
Global $mb_inbox_handles[]
Global $mb_inbox_bases[]


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


Func CreateMultiboxEventLogBlock()
	Local $headerSize = DllStructGetSize(DllStructCreate($EVENT_LOG_HEADER_TEMPLATE))
	Local $entrySize = DllStructGetSize(DllStructCreate($EVENT_LOG_ENTRY_TEMPLATE))
	Local $totalSize = $headerSize + ($entrySize * $EVENT_LOG_SIZE)

	Local $handle = SafeDllCall15($kernel_handle, 'handle', 'CreateFileMappingW', _
		'handle', -1, _
		'ptr', 0, _
		'dword', $PAGE_READWRITE, _
		'dword', 0, _
		'dword', $totalSize, _
		'wstr', $EVENT_LOG_BLOCK)
	If @error Or $handle[0] = 0 Then
		Error('Failed to create event log shared memory block.')
		Return False
	EndIf
	$mb_event_log_handle = $handle[0]

	Local $address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'dword', 0, _
		'dword', 0, _
		'dword', $totalSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Error('Failed to map event log shared memory.')
		Return False
	EndIf
	$mb_event_log_base = $address[0]

	; Header at the start
	$mb_event_header_struct = DllStructCreate($EVENT_LOG_HEADER_TEMPLATE, $address[0])
	DllStructSetData($mb_event_header_struct, 'writeIndex', 0)

	; Event entries after the header
	For $i = 0 To $EVENT_LOG_SIZE - 1
		$mb_event_structs[$i] = DllStructCreate($EVENT_LOG_ENTRY_TEMPLATE, $address[0] + $headerSize + ($i * $entrySize))
		DllStructSetData($mb_event_structs[$i], 'active', 0)
	Next

	Info('Created multibox event log block (' & $totalSize & ' bytes, ' & $EVENT_LOG_SIZE & ' entries)')
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

	For $i = 0 To $INBOX_MESSAGE_COUNT - 1
		$mb_inbox_structs[$i] = DllStructCreate($INBOX_MESSAGE_TEMPLATE, $address[0] + ($i * $msgSize))
		; Clear any stale messages from previous sessions
		DllStructSetData($mb_inbox_structs[$i], 'active', 0)
	Next
	_MBFileLog('Cleared own inbox (' & $INBOX_MESSAGE_COUNT & ' slots zeroed)')

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

	; --- Open Event Log Block ---
	Local $headerSize = DllStructGetSize(DllStructCreate($EVENT_LOG_HEADER_TEMPLATE))
	Local $entrySize = DllStructGetSize(DllStructCreate($EVENT_LOG_ENTRY_TEMPLATE))
	Local $eventLogSize = $headerSize + ($entrySize * $EVENT_LOG_SIZE)

	$handle = SafeDllCall9($kernel_handle, 'handle', 'OpenFileMappingW', _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'bool', False, _
		'wstr', $EVENT_LOG_BLOCK)
	If @error Or $handle[0] = 0 Then
		_MBFileLog('FAIL: open event log block')
		Error('Failed to open event log shared memory block.')
		Return False
	EndIf
	$mb_event_log_handle = $handle[0]

	$address = SafeDllCall13($kernel_handle, 'ptr', 'MapViewOfFile', _
		'handle', $handle[0], _
		'dword', BitOR($FILE_MAP_READ, $FILE_MAP_WRITE), _
		'dword', 0, _
		'dword', 0, _
		'dword', $eventLogSize)
	If @error Or $address[0] = 0 Then
		SafeDllCall5($kernel_handle, 'int', 'CloseHandle', 'int', $handle[0])
		Error('Failed to map event log shared memory.')
		Return False
	EndIf
	$mb_event_log_base = $address[0]

	$mb_event_header_struct = DllStructCreate($EVENT_LOG_HEADER_TEMPLATE, $address[0])
	For $i = 0 To $EVENT_LOG_SIZE - 1
		$mb_event_structs[$i] = DllStructCreate($EVENT_LOG_ENTRY_TEMPLATE, $address[0] + $headerSize + ($i * $entrySize))
	Next
	; Start reading from the current position
	$mb_event_read_cursor = DllStructGetData($mb_event_header_struct, 'writeIndex')

	_MBFileLog('SUCCESS: Opened all multibox shared memory for slot ' & $slaveIndex)
	Info('Opened multibox shared memory for slot ' & $slaveIndex & ' (total slaves: ' & $totalSlaves & ')')
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

Func SendMultiboxMessage($targetSlaveIndex, $command, $param1 = 0, $param2 = 0, $param3 = 0, $param4 = 0, $extraData = '')
	If $mb_my_slot >= 0 And $targetSlaveIndex = $mb_my_slot Then Return False
	If Not MapExists($mb_outbox_structs, $targetSlaveIndex) Then
		Warn('No outbox connection to slave ' & $targetSlaveIndex)
		Return False
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

Func BroadcastEvent($eventType, $targetAgentID = 0, $skillID = 0)
	If $mb_event_header_struct = Null Then Return

	; Read current write position, write entry, increment
	Local $writeIdx = DllStructGetData($mb_event_header_struct, 'writeIndex')
	Local $entryIdx = Mod($writeIdx, $EVENT_LOG_SIZE)

	DllStructSetData($mb_event_structs[$entryIdx], 'slaveIndex', $mb_my_slot)
	DllStructSetData($mb_event_structs[$entryIdx], 'eventType', $eventType)
	DllStructSetData($mb_event_structs[$entryIdx], 'targetAgentID', $targetAgentID)
	DllStructSetData($mb_event_structs[$entryIdx], 'skillID', $skillID)

	Local $tick = DllCall('kernel32.dll', 'dword', 'GetTickCount')
	If Not @error Then DllStructSetData($mb_event_structs[$entryIdx], 'timestamp', $tick[0])

	; Set active last
	DllStructSetData($mb_event_structs[$entryIdx], 'active', 1)

	; Increment shared write index
	DllStructSetData($mb_event_header_struct, 'writeIndex', $writeIdx + 1)

	MBDebug('Event: type=' & $eventType & ' target=' & $targetAgentID & ' skill=' & $skillID)
EndFunc


Func ReadNewEvents()
	If $mb_event_header_struct = Null Then
		Local $empty[0]
		Return $empty
	EndIf

	Local $writeIdx = DllStructGetData($mb_event_header_struct, 'writeIndex')
	Local $events[0]

	While $mb_event_read_cursor < $writeIdx
		Local $entryIdx = Mod($mb_event_read_cursor, $EVENT_LOG_SIZE)

		If DllStructGetData($mb_event_structs[$entryIdx], 'active') = 1 Then
			Local $evt[]
			$evt['slaveIndex'] = DllStructGetData($mb_event_structs[$entryIdx], 'slaveIndex')
			$evt['eventType'] = DllStructGetData($mb_event_structs[$entryIdx], 'eventType')
			$evt['targetAgentID'] = DllStructGetData($mb_event_structs[$entryIdx], 'targetAgentID')
			$evt['skillID'] = DllStructGetData($mb_event_structs[$entryIdx], 'skillID')
			$evt['timestamp'] = DllStructGetData($mb_event_structs[$entryIdx], 'timestamp')

			ReDim $events[UBound($events) + 1]
			$events[UBound($events) - 1] = $evt
		EndIf

		$mb_event_read_cursor += 1
	WEnd

	Return $events
EndFunc


Func ReadEventsByType($eventType)
	Local $allEvents = ReadNewEvents()
	Local $filtered[0]
	For $i = 0 To UBound($allEvents) - 1
		If $allEvents[$i]['eventType'] = $eventType Then
			ReDim $filtered[UBound($filtered) + 1]
			$filtered[UBound($filtered) - 1] = $allEvents[$i]
		EndIf
	Next
	Return $filtered
EndFunc


; ==================== DEBUG LOGGER ====================

Func MultiboxLog($message, $level = 'INF')
	Local $formatted = '[' & $MB_DEBUG_SENDER & ':' & $level & '] ' & $message
	WriteChat($formatted, $MB_DEBUG_SENDER)
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

	; Unmap and close event log block
	If $mb_event_log_base <> 0 Then
		SafeDllCall5($kernel_handle, 'bool', 'UnmapViewOfFile', 'ptr', $mb_event_log_base)
		$mb_event_log_base = 0
	EndIf
	If $mb_event_log_handle <> 0 Then
		SafeDllCall5($kernel_handle, 'bool', 'CloseHandle', 'handle', $mb_event_log_handle)
		$mb_event_log_handle = 0
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
	Local $logFile = @ScriptDir & '\multibox_debug.log'
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
	If $mb_deferred_count = 0 Then Return

	_MBFileLog('ProcessDeferredCommands: executing ' & $mb_deferred_count & ' command(s)')

	Local $count = $mb_deferred_count
	; Reset count first so new commands arriving during execution go to the queue
	$mb_deferred_count = 0
	For $i = 0 To $count - 1
		ExecuteMultiboxCommand($mb_deferred_commands[$i])
		$mb_deferred_commands[$i] = Null
	Next
EndFunc


; Re-read the game's queue counter to keep the local copy in sync
Func SyncQueueCounter()
	Local $gameCounter = MemoryRead(GetProcessHandle(), GetLabel('QueueCounter'))
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
			Local $senderState = ReadAccountState($sender)
			If $senderState <> Null Then
				_MBFileLog('Following slave ' & $sender & ' (' & $senderState['characterName'] & ')')
				Info('Following slave ' & $sender & ' (' & $senderState['characterName'] & ')')
				SyncQueueCounter()
				Move($senderState['posX'], $senderState['posY'])
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

		Case $CMD_RESURRECT
			_MBFileLog('Resurrect command from slave ' & $sender)
			Info('Resurrect command from slave ' & $sender)

		Case $CMD_PICK_UP_LOOT
			_MBFileLog('Loot command from slave ' & $sender)
			Info('Loot command from slave ' & $sender)

		Case $CMD_INVITE_TO_PARTY
			_MBFileLog('Party invite command from slave ' & $sender)
			Info('Party invite command from slave ' & $sender)

		Case $CMD_CUSTOM
			_MBFileLog('Custom command from slave ' & $sender & ': ' & $msg['extraData'])
			Info('Custom command from slave ' & $sender & ': ' & $msg['extraData'])

		Case Else
			_MBFileLog('Unknown multibox command: ' & $cmd & ' from slave ' & $sender)
			Warn('Unknown multibox command: ' & $cmd & ' from slave ' & $sender)
	EndSwitch
EndFunc


Func CleanupMultibox()
	AdlibUnRegister('PublishAccountState')
	AdlibUnRegister('ProcessInboxMessages')
	CloseMultiboxSharedMemory()
EndFunc
