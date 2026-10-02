program PidkovaD6NReceiver;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Winapi.Windows,
  IdTCPClient,
  IdException;

type
  TTestCard = record
    CardNumber: string;
    Open: Boolean;
  end;

const
  TestCards: array[0..3] of TTestCard = (
    (CardNumber: 'C444C262'; Open: True),
    (CardNumber: '00000001'; Open: False),
    (CardNumber: '12345678'; Open: True),
    (CardNumber: 'ABCDEF01'; Open: False)
  );

procedure LogOperation(const Operation: string);
var
  LogLines: TStringList;
  LogFileName: string;
begin
  LogFileName := TPath.Combine(ExtractFilePath(ParamStr(0)),
    'PidkovaD6NReceiver.log');

  LogLines := TStringList.Create;
  try
    try
      if TFile.Exists(LogFileName) then
        LogLines.LoadFromFile(LogFileName, TEncoding.UTF8);

      LogLines.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' | ' +
        Operation);

      while LogLines.Count > 100 do
        LogLines.Delete(0);

      LogLines.SaveToFile(LogFileName, TEncoding.UTF8);
    except
      on E: Exception do
        Writeln(ErrOutput, 'Log error: ', E.Message);
    end;
  finally
    LogLines.Free;
  end;
end;

function IsHex(const Value: string): Boolean;
var
  Index: Integer;
begin
  Result := Value <> '';
  for Index := 1 to Length(Value) do
    if not CharInSet(UpCase(Value[Index]), ['0'..'9', 'A'..'F']) then
      Exit(False);
end;

function TryParseCardFrame(const Line: string; out DeviceNumber, Side,
  CardNumber: string): Boolean;
var
  Frame: string;
begin
  Result := False;
  Frame := Trim(Line);
  if (Length(Frame) <> 17) or (Frame[1] <> '$') or
    (Copy(Frame, 6, 2) <> 'RQ') then
    Exit;

  DeviceNumber := Copy(Frame, 2, 3);
  Side := Copy(Frame, 5, 1);
  CardNumber := UpperCase(Copy(Frame, 8, 8));

  Result := (Length(DeviceNumber) = 3) and
    (DeviceNumber[1] in ['0'..'9']) and
    (DeviceNumber[2] in ['0'..'9']) and
    (DeviceNumber[3] in ['0'..'9']) and
    (Side[1] in ['A', 'B']) and
    IsHex(CardNumber) and IsHex(Copy(Frame, 16, 2));
end;

function CalculateCRC8(const Value: string): Byte;
var
  Index, BitIndex: Integer;
  CRC: Cardinal;
begin
  CRC := $FF;
  for Index := 1 to Length(Value) do
  begin
    CRC := CRC xor Ord(Value[Index]);
    for BitIndex := 0 to 7 do
      if (CRC and $80) <> 0 then
        CRC := ((CRC shl 1) xor $31) and $FF
      else
        CRC := (CRC shl 1) and $FF;
  end;
  Result := Byte(CRC);
end;

procedure SendControllerCommand(Client: TIdTCPClient; const CommandBody: string);
var
  Frame: string;
begin
  if not Client.Connected then
    raise Exception.Create('Controller is not connected.');

  Frame := '$' + CommandBody + IntToHex(CalculateCRC8(CommandBody), 2);
  Client.IOHandler.WriteLn(Frame, IndyTextEncoding_ASCII);
  LogOperation('Controller command sent: ' + Frame);
end;

procedure OpenTurnstile(Client: TIdTCPClient; const DeviceNumber: string;
  Side: Char);
var
  CommandBody: string;
  Index: Integer;
begin
  if Length(DeviceNumber) <> 3 then
    raise Exception.Create('Controller number must contain three digits.');
  for Index := 1 to Length(DeviceNumber) do
    if not CharInSet(DeviceNumber[Index], ['0'..'9']) then
      raise Exception.Create('Controller number must contain three digits.');
  if not (Side in ['A', 'a', 'B', 'b']) then
    raise Exception.Create('Turnstile side must be A or B.');

  CommandBody := DeviceNumber + UpCase(Side) + 'GO';
  SendControllerCommand(Client, CommandBody);
end;

procedure ShowTurnstileMessage(Client: TIdTCPClient; const DeviceNumber: string;
  Side: Char; const MessageText: string);
var
  CommandBody: string;
  Index: Integer;
begin
  if Length(DeviceNumber) <> 3 then
    raise Exception.Create('Controller number must contain three digits.');
  for Index := 1 to Length(DeviceNumber) do
    if not CharInSet(DeviceNumber[Index], ['0'..'9']) then
      raise Exception.Create('Controller number must contain three digits.');
  if not (Side in ['A', 'a', 'B', 'b']) then
    raise Exception.Create('Turnstile side must be A or B.');
  if (Length(MessageText) = 0) or (Length(MessageText) > 20) then
    raise Exception.Create('Display message must contain 1 to 20 characters.');
  for Index := 1 to Length(MessageText) do
    if (Ord(MessageText[Index]) < 32) or (Ord(MessageText[Index]) > 126) then
      raise Exception.Create('Display message must contain ASCII characters.');

  CommandBody := DeviceNumber + UpCase(Side) + 'PSN2001' + MessageText;
  SendControllerCommand(Client, CommandBody);
  LogOperation('Turnstile display message: ' + MessageText);
end;

procedure OpenGate(Client: TIdTCPClient; const CardNumber, DeviceNumber: string;
  Side: Char);
var
  Index: Integer;
begin
  for Index := Low(TestCards) to High(TestCards) do
    if TestCards[Index].CardNumber = CardNumber then
    begin
      if TestCards[Index].Open then
      begin
        LogOperation('Access granted for card ' + CardNumber);
        OpenTurnstile(Client, DeviceNumber, Side);
        ShowTurnstileMessage(Client, DeviceNumber, Side, 'ACCESS GRANTED');
      end
      else
      begin
        LogOperation('Access denied for card ' + CardNumber + ': open=0');
        ShowTurnstileMessage(Client, DeviceNumber, Side, 'ACCESS DENIED');
      end;
      Exit;
    end;

  LogOperation('Access denied for unknown card ' + CardNumber);
  ShowTurnstileMessage(Client, DeviceNumber, Side, 'CARD NOT FOUND');
end;

procedure RunReceiver(const Host: string; Port: Integer);
var
  Client: TIdTCPClient;
  Line, DeviceNumber, Side, CardNumber: string;
begin
  Client := TIdTCPClient.Create(nil);
  try
    Client.Host := Host;
    Client.Port := Port;
    Client.ConnectTimeout := 5000;
    Client.ReadTimeout := 1000;
    LogOperation(Format('Receiver started for %s:%d', [Host, Port]));

    while True do
    begin
      try
        if not Client.Connected then
        begin
          LogOperation(Format('Connecting to %s:%d', [Host, Port]));
          Client.Connect;
          LogOperation('TCP connection established');
        end;

        try
          Line := Client.IOHandler.ReadLn(#10, 1000);
        except
          on E: EIdReadTimeout do
            Continue;
        end;

        if TryParseCardFrame(Line, DeviceNumber, Side, CardNumber) then
        begin
          LogOperation('Card frame received: ' + Line);
          OpenGate(Client, CardNumber, DeviceNumber, Side);
        end
        else
          LogOperation('Ignored controller message: ' + Line);
      except
        on E: Exception do
        begin
          LogOperation('Connection/processing error: ' + E.Message);
          if Client.Connected then
            Client.Disconnect;
          Writeln(ErrOutput, 'Connection error: ', E.Message);
          Sleep(1000);
        end;
      end;
    end;
  finally
    Client.Free;
  end;
end;

var
  Port: Integer;
begin
  LogOperation('Program started');
  if ParamCount <> 2 then
  begin
    LogOperation('Invalid parameters');
    Writeln(ErrOutput, 'Usage: PidkovaD6NReceiver.exe <controller-ip> <port>');
    Halt(2);
  end;

  if not TryStrToInt(ParamStr(2), Port) or (Port < 1) or (Port > 65535) then
  begin
    LogOperation('Invalid TCP port: ' + ParamStr(2));
    Writeln(ErrOutput, 'Port must be an integer from 1 to 65535.');
    Halt(2);
  end;

  try
    RunReceiver(ParamStr(1), Port);
  except
    on E: Exception do
    begin
      LogOperation('Fatal error: ' + E.Message);
      Writeln(ErrOutput, E.Message);
      Halt(1);
    end;
  end;
end.