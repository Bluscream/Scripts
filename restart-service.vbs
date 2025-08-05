If WScript.Arguments.Count = 0 Then
    WScript.Quit 1
End If
Set objShell = CreateObject("WScript.Shell")
Dim services()
ReDim services(WScript.Arguments.Count - 1)
For i = 0 To WScript.Arguments.Count - 1
    services(i) = WScript.Arguments(i)
Next
For i = 0 To UBound(services)
    objShell.Run "sc stop """ & services(i) & """", 0, True
Next
WScript.Sleep 1000
For i = UBound(services) To 0 Step -1
    objShell.Run "sc start """ & services(i) & """", 0, False
Next
Set objShell = Nothing 