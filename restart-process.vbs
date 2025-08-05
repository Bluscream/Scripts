If WScript.Arguments.Count = 0 Then
    WScript.Quit 1
End If
Set objShell = CreateObject("WScript.Shell")
Dim processes()
ReDim processes(WScript.Arguments.Count - 1)
For i = 0 To WScript.Arguments.Count - 1
    processes(i) = WScript.Arguments(i)
Next
For i = 0 To UBound(processes)
    objShell.Run "taskkill /f /im """ & processes(i) & """", 0, True
Next
WScript.Sleep 1000
For i = UBound(processes) To 0 Step -1
    objShell.Run """" & processes(i) & """", 0, False
Next
Set objShell = Nothing 