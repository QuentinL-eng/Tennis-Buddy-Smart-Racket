' RC+ 7.5 manual-checked candidate. Build and motion tests are still required.
' P0/P2/P1 are treated as FLANGE poses (Tool 0), as in PROTOCOL.md.
' The point file does not record the tool used when the points were taught.
' Do not select Tool 1 for these points without conversion or teaching again.

Function racket_setup
    Robot 1
    ' MOTOR ON IS AN OPERATOR ACTION. No automatic Motor On is permitted here.
    Power Low
    Speed 20
    Accel 20, 20
    SpeedS 100
    AccelS 200, 200
    Tool 0
    ' Do not write Weight, Inertia or TLSet on each run.
    ' Set the measured payload and tool once in Robot Manager.
Fend

Function racket_home
    racket_setup
    Go P0
    Print "At P0: flange home"
Fend

' Original Y-endpoint sweep. Go is joint interpolation, not a straight Y path.
' Passing through P2 is not guaranteed. No contact speed is claimed.
Function racket_swing
    racket_setup
    Go P0
    Wait 0.5
    Go P1
    Print "Y-endpoint sweep finished at P1"
Fend

' Stop at the contact point for a separate reach and collision check.
Function racket_check_contact
    racket_setup
    Go P2
    Print "At P2: flange contact"
Fend

Function racket_check_post
    racket_setup
    Go P1
    Print "At P1: flange follow-through"
Fend

' Linear comparison: no stop at the collinear P2 waypoint.
' SpeedS is mm/s at Tool 0, not measured racket-head speed.
Function racket_swing_linear
    racket_setup
    Go P0
    Wait 0.5
    Move P2 CP
    Move P1
    Print "Linear sweep finished at P1"
Fend

' Pass is an experiment only: the manual says it can miss the waypoint.
Function racket_swing_pass
    racket_setup
    Go P0
    Wait 0.5
    Pass P2, P1
    Go P1
    Print "Pass test finished; contact at P2 is not guaranteed"
Fend

' Candidate arc about the joint posture at P2.
' Only J1 and J2 differ at the endpoints; J3-J6 use their P2 values.
' P20/P21/P22 are temporary points. The source points are unchanged.
' NOT reach/collision verified. Use only in the isolated virtual test project.
Function racket_swing_arc
    Real a1, a2, a3, a4, a5, a6
    racket_setup
    Go P2
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
Fend
