' ============================================================================
' TennisRobot strike server - REFERENCE SKELETON
'
' STATUS: not compiled or tested on an RC700-E.  Verify every command below
' against the SPEL+ Language Reference for your RC+ version before running.
' In particular: SetNet/OpenNet arguments, comma-separated Input, Str$/Print
' framing, point U,V,W convention, Wait units and the approach timing.
'
' Protocol (fixed 22 comma-separated fields, LF terminated):
'   1,seq, pre_x,y,z,u,v,w, strike_x,y,z,u,v,w, post_x,y,z,u,v,w, speed, lead_ms
'   2,seq, 0 x20   (abort)
'   3,seq, 0 x20   (ping)
' Replies: ACK,seq  /  DONE,seq  /  ERR,seq,code  /  PONG,seq
'
' All poses arrive in the Epson base frame, millimetres and degrees, already
' converted by the Linux side.  Motion stays on the controller.
'
' WARNING: this program can move a robot fast.  Cell guarding, a hardwired
' E-stop on the controller's safety circuit, a restricted work envelope and a
' measured approach time are prerequisites, not optional extras.
' ============================================================================

Function main
    Integer op, seq, err
    Real x1, y1, z1, u1, v1, w1
    Real x2, y2, z2, u2, v2, w2
    Real x3, y3, z3, u3, v3, w3
    Real speed, lead_ms, wait_s, approach_ms

    ' EDIT: measured time from starting the swing to the racket crossing the
    ' strike pose.  Start with a very slow speed and measure it externally.
    approach_ms = 250.0

    ' EDIT: logical OpenNet port and TCP port.  Verify the argument order.
    ' SetNet #201, 12000, CRLF, NONE, 0
    OpenNet #201 As Server

    Do
        Input #201, op, seq, x1, y1, z1, u1, v1, w1, x2, y2, z2, u2, v2, w2, x3, y3, z3, u3, v3, w3, speed, lead_ms

        If op = 3 Then
            ' Heartbeat.  This single-task server can only answer between
            ' motions; see epson/README.md.
            Print #201, "PONG," + Str$(seq)

        ElseIf op = 2 Then
            ' The Linux side aborted.  Stop the current motion immediately.
            ' Motor-off behaviour is controller-configured; do not add an
            ' automatic Off here.
            Print #201, "ACK," + Str$(seq)

        ElseIf op = 1 Then
            err = 0

            ' EDIT: conservative envelope in the base frame (mm).  This must
            ' cover the whole racket, not just the flange, and must be checked
            ' against the real cell.  Error codes are for the log only.
            If x1 < 250 Or x1 > 850 Then
                err = 11
            ElseIf x2 < 250 Or x2 > 850 Then
                err = 12
            ElseIf x3 < 250 Or x3 > 850 Then
                err = 13
            ElseIf Abs(y1) > 600 Or Abs(y2) > 600 Or Abs(y3) > 600 Then
                err = 14
            ElseIf z1 < 150 Or z1 > 1400 Then
                err = 15
            ElseIf z2 < 150 Or z2 > 1400 Then
                err = 16
            ElseIf z3 < 150 Or z3 > 1400 Then
                err = 17
            ElseIf speed < 100 Or speed > 2500 Then
                err = 21
            ElseIf lead_ms < 50 Or lead_ms > 1000 Then
                err = 22
            EndIf

            If err <> 0 Then
                Print #201, "ERR," + Str$(seq) + "," + Str$(err)
            Else
                Print #201, "ACK," + Str$(seq)

                ' Move to the pre-swing pose slowly; it is behind the ball.
                Speed 150
                Go P(x1, y1, z1, u1, v1, w1)

                ' Wait for the commanded lead to expire, minus the measured
                ' swing time.  This is approximate; measure and tune it, or
                ' trigger from a hardware input for repeatable timing.
                wait_s = (lead_ms - approach_ms) / 1000.0
                If wait_s > 0.0 Then
                    Wait wait_s
                EndIf

                ' Sweep through the strike pose and out to the post pose.
                Speed speed
                Move P(x2, y2, z2, u2, v2, w2)
                Move P(x3, y3, z3, u3, v3, w3)

                Print #201, "DONE," + Str$(seq)
            EndIf

        Else
            Print #201, "ERR," + Str$(seq) + ",3"
        EndIf
    Loop
Fend
