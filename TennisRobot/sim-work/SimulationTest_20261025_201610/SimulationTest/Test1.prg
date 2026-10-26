Function test1
	Print "test1 started"
    Motor On
    Power High
    Speed 50
    Accel 50, 50
    
    SpeedS 100
    AccelS 30000, 30000
    
    ' Move through taught points
    Go Zero
   
    Print "Simulation run complete!"
Fend
