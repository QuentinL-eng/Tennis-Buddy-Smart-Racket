' Racket test moves for the RC+ 7.5 simulator (C8L). Not run on a real arm.
' Function names must be unique across the project.
'
' Uses the points already in robot1.pts:
'   P0 = Start (home), P2 = MiddleSpot (contact), P1 = HitSpot1 (follow-through)
' All three share X=-550, Z=500, U=90, so the swing is a sweep along Y.

Function racket_setup
    Motor On
    Power Low
    Weight 0.35, 450          ' kg, mm from wrist centre to racket CoM - check vs Onshape
    ' Tool 1 = centre of the string face. CHECK the axis and sign in the simulator.
    ' If P0/P1/P2 were taught with the flange (Tool 0), delete both lines below,
    ' or the poses will be offset by 450 mm and may be out of reach.
    TLSet 1, XY(0, 0, 450, 0, 0, 0)
    Tool 1
Fend

Function racket_home
    racket_setup
    Speed 20
    Accel 20, 20
    Go P0
    Print "At home"
Fend

' Swing from P0 through P2 (contact) to P1. The arm stops at P1, past the contact point.
Function racket_swing
    Integer spd
    spd = 20                  ' raise in steps: 20, 35, 50, 70, 100

    racket_setup
    Speed 20
    Accel 20, 20
    Go P0                     ' wind back slowly
    Wait 0.5

    Power High
    Speed spd
    Accel spd, spd
    Go P1                     ' passes P2 mid-motion; stop is beyond contact
    Print "Swing done"

    Power Low
    Speed 20
    Accel 20, 20
    Go P0                     ' return
Fend
