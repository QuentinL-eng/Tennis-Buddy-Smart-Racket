' SIMULATION PROTOTYPE ONLY: no ball, no actual-trajectory logger.
' The racket is assumed to extend along flange +Y. Tool 1 is a provisional
' 450 mm flange-to-head offset from the existing simulator project.
' Set the robot at the desired start pose in the simulator before running.
' All joint positions below are offsets from that starting pose in degrees.
' No physical-cell safety zone, payload commissioning or collision proof exists.

Global Real g_j1, g_j2, g_j3, g_j4, g_j5, g_j6
Global Real g_arc_deg, g_sync_deg, g_hold_s, g_pause_s
Global Integer g_speed_pct, g_accel_pct, g_reps

Function sim_wrist_setup
    g_speed_pct = 10
    g_accel_pct = 10
    g_arc_deg = 15
    g_sync_deg = 2
    g_hold_s = 1
    g_pause_s = 1
    g_reps = 3
    Robot 1
    Power Low
    Speed g_speed_pct
    Accel g_accel_pct, g_accel_pct
    TLSet 1, XY(0, 450, 0, 0, 0, 0)
    Tool 1
    g_j1 = Agl(1)
    g_j2 = Agl(2)
    g_j3 = Agl(3)
    g_j4 = Agl(4)
    g_j5 = Agl(5)
    g_j6 = Agl(6)
Fend

Function sim_wrist_sync
    ' Tentative J5 twitch: its axis must be checked against racket +x.
    Wait g_hold_s
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5 + g_sync_deg, g_j6)
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6)
    Wait g_hold_s
Fend

Function sim_air_forehand
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6 - g_arc_deg)
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6 + g_arc_deg)
Fend

Function sim_air_backhand
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6 + g_arc_deg)
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6 - g_arc_deg)
Fend

Function sim_forehand_run(speedPct As Integer)
    Integer rep
    sim_wrist_setup
    Speed speedPct
    For rep = 1 To g_reps
        Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6)
        sim_wrist_sync
        sim_air_forehand
        Wait g_pause_s
    Next rep
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6)
Fend

Function sim_backhand_run(speedPct As Integer)
    Integer rep
    sim_wrist_setup
    Speed speedPct
    For rep = 1 To g_reps
        Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6)
        sim_wrist_sync
        sim_air_backhand
        Wait g_pause_s
    Next rep
    Go JA(g_j1, g_j2, g_j3, g_j4, g_j5, g_j6)
Fend

Function sim_forehand_slow
    sim_forehand_run 5
Fend

Function sim_forehand_medium
    sim_forehand_run 10
Fend

Function sim_forehand_fast
    sim_forehand_run 20
Fend

Function sim_backhand_slow
    sim_backhand_run 5
Fend

Function sim_backhand_medium
    sim_backhand_run 10
Fend

Function sim_backhand_fast
    sim_backhand_run 20
Fend
