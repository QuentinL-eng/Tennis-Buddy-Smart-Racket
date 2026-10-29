' RC+ 7.5 simulator tests. P0 is unreachable with Tool 0; see SIM_FINDINGS.md.
' Test convention: points use Tool 0. Historical teaching tool is unknown.
Function racket_setup
    Robot 1
    ' MOTOR ON IS AN OPERATOR ACTION. No automatic Motor On here.
    Power Low
    Speed 20
    Accel 20, 20
    SpeedS 100
    AccelS 200, 200
    Tool 0
Fend

Function racket_home
    racket_setup
    If TargetOK(P0) Then
        Go P0
        Print "At P0: flange home"
    Else
        Print "BLOCKED: P0 is unreachable with Tool 0"
    EndIf
Fend

Function racket_swing
    racket_setup
    If TargetOK(P0) And TargetOK(P1) Then
        Go P0
        Wait 0.5
        Go P1
        Print "Y-endpoint sweep finished at P1"
    Else
        Print "BLOCKED: sweep endpoint unreachable with Tool 0"
    EndIf
Fend

Function racket_check_contact
    racket_setup
    ' Below changes the arm branch for this move; robot1.pts stays unchanged.
    If TargetOK(P2 /B) Then
        ' Go P2 /B is disabled: C8 turned red during the test.
        Print "BLOCKED: P2 below caused a C8 collision indication"
    Else
        Print "BLOCKED: P2 below is unreachable"
    EndIf
Fend

Function racket_check_post
    racket_setup
    If TargetOK(P1) Then
        Go P1
        Print "At P1: flange follow-through"
    Else
        Print "BLOCKED: P1 is unreachable"
    EndIf
Fend

Function racket_swing_linear
    racket_setup
    If TargetOK(P0) And TargetOK(P2 /B) And TargetOK(P1) Then
        Go P0
        Wait 0.5
        Move P2 /B CP
        Move P1
        Print "Linear sweep finished at P1"
    Else
        Print "BLOCKED: entry or endpoint unreachable"
    EndIf
Fend

Function racket_swing_pass
    racket_setup
    If TargetOK(P0) And TargetOK(P2 /B) And TargetOK(P1) Then
        Go P0
        Wait 0.5
        Pass P2 /B, P1
        Go P1
        Print "Pass test finished; contact at P2 is not guaranteed"
    Else
        Print "BLOCKED: entry or endpoint unreachable"
    EndIf
Fend

Function racket_swing_arc
    Real a1, a2, a3, a4, a5, a6
    racket_setup
    ' Entry P2 below produced a C8 collision. Do not run the arc yet.
    If False Then
        Go P2 /B
        a1 = Agl(1)
        a2 = Agl(2)
        a3 = Agl(3)
        a4 = Agl(4)
        a5 = Agl(5)
        a6 = Agl(6)
        P20 = JA(a1 - 10, a2 - 5, a3, a4, a5, a6)
        P21 = JA(a1, a2, a3, a4, a5, a6)
        P22 = JA(a1 + 10, a2 + 5, a3, a4, a5, a6)
        Go P20
        Wait 0.5
        Pass P21, P22
        Go P22
        Print "J1/J2 arc finished; contact at P21 is not guaranteed"
    Else
        Print "BLOCKED: arc held after C8 collision"
    EndIf
Fend

Function racket_reach_report
    Robot 1
    Tool 0
    Print "Tool 0 P0/P2/P1:", TargetOK(P0), TargetOK(P2), TargetOK(P1)
    Print "Tool 0 P2 below:", TargetOK(P2 /B)
Fend

Function racket_alt_home
    racket_setup
    If TargetOK(P0 :V(-90) :W(-90)) Then
        Go P0 :V(-90) :W(-90)
        Print "At P0 XYZ, alternative V/W -90"
    EndIf
Fend

Function racket_alt_contact
    racket_setup
    If TargetOK(P2 :V(-90) :W(-90)) Then
        Go P2 :V(-90) :W(-90)
        Print "At P2 XYZ, alternative V/W -90"
    EndIf
Fend

Function racket_alt_post
    racket_setup
    If TargetOK(P1 :V(-90) :W(-90)) Then
        Go P1 :V(-90) :W(-90)
        Print "At P1 XYZ, alternative V/W -90"
    EndIf
Fend

