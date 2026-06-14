import 'dart:convert';
import 'dart:io';
import 'package:utopic/src/acp/acp_server.dart';

void main() async {
  final server = AcpServer(host: '127.0.0.1', port: 0);
  
  server.registerHandler('initialize', (request) async {
    print('HANDLER CALLED');
    return {'server_name': 'test', 'server_version': '1.0'};
  });

  await server.start();
  final port = server.boundPort!;
  print('SERVER READY on port $port');
  
  final socket = await Socket.connect('127.0.0.1', port);
  var gotResponse = false;
  
  socket.listen((data) {
    print('RESPONSE: ${utf8.decode(data)}');
    gotResponse = true;
  });
  
  await Future.delayed(Duration(milliseconds: 100));
  socket.write('{"jsonrpc":"2.0","id":1,"method":"initialize"}\n');
  print('REQUEST SENT');
  
  await Future.delayed(Duration(seconds: 2));
  print('Got response: $gotResponse');
  print(gotResponse ? 'PASS' : 'FAIL');
  
  await socket.close();
  await server.stop();
  exit(gotResponse ? 0 : 1);
}
