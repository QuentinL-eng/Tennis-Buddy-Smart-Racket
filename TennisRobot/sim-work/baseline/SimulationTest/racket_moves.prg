' Racket test moves for the RC+ 7.5 simulator (C8L). Not run on a real arm.
' Function names must be unique across the project.
'
' One-time setup in Jog & Teach, then Save Points:
'   P10 = home pose (the pose you want "default" to be)
' Everything else is derived from P10 so the swing stays in the same plane.

Function racket_setup
    Motor On
    Power Low
    Weight 0.35, 450          ' kg, mm from wrist centre to racket CoM - check vs Onshape
    ' Tool 1 = centre of the string face. CHECK the axis and sign in the simulator.
    TLSet 1, XY(0, 0, 450, 0, 0, 0)
    Tool 1
Fend

Function racket_home
    racket_setup
    Speed 20
    Accel 20, 20
    Go P10
    Print "At home"
Fend

' Swing along Y with X, Z and orientation held (joint-space Go, so X/Z may deviate
' slightly mid-path; use Move instead if they must stay exact, but it is slower).
Function racket_swing
    Integer spd
    Real backswing, followthrough
    spd = 20                  ' raise in steps: 20, 35, 50, 70, 100
    backswing = -300          ' mm behind home along Y
    followthrough = 400       ' mm past home along Y; contact point should be between

    racket_setup
    Speed 20
    Accel 20, 20
    Go P10 +Y(backswing)      ' wind back slowly
    Wait 0.5

    Power High
    Speed spd
    Accel spd, spd
    Go P10 +Y(followthrough)  ' contact happens mid-motion, stop is beyond it
    Print "Swing done"

    Power Low
    Speed 20
    Accel 20, 20
    Go P10                    ' return
Fend
