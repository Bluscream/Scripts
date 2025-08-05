If WScript.Arguments.Count = 0 Then
    WScript.Quit 1
End If
Set objShell = CreateObject("WScript.Shell")
Dim tasks()
ReDim tasks(WScript.Arguments.Count - 1)
For i = 0 To WScript.Arguments.Count - 1
    tasks(i) = WScript.Arguments(i)
Next
For i = 0 To UBound(tasks)
    objShell.Run "schtasks /end /tn """ & tasks(i) & """", 0, True
Next
WScript.Sleep 1000
For i = UBound(tasks) To 0 Step -1
    objShell.Run "schtasks /run /tn """ & tasks(i) & """", 0, False
Next
Set objShell = Nothing 