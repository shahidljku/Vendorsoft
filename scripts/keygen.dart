// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:encrypt/encrypt.dart';
// ignore: depend_on_referenced_packages
import 'package:pointycastle/asymmetric/api.dart';

const String privateKeyString = '''
[REDACTED_RSA_PRIVATE_KEY]
''';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Usage: dart keygen.dart <Device ID> [Customer/Company Name]');
    return;
  }

  final deviceId = args[0];
  final companyName = args.length > 1 ? args[1] : 'Unknown Customer';

  final payload = {
    'deviceId': deviceId,
    'companyName': companyName,
    'activationDate': DateTime.now().toIso8601String(),
  };

  final payloadStr = jsonEncode(payload);

  final parser = RSAKeyParser();
  final privateKey = parser.parse(privateKeyString) as RSAPrivateKey;
  
  final signer = Signer(RSASigner(RSASignDigest.SHA256, privateKey: privateKey));
  final signature = signer.sign(payloadStr);

  final licenseObj = {
    'payload': payloadStr,
    'signature': signature.base64,
  };

  final licenseKey = base64Encode(utf8.encode(jsonEncode(licenseObj)));

  print('=================================');
  print('LICENSE KEY FOR DEVICE: $deviceId');
  print('CUSTOMER: $companyName');
  print('=================================');
  print(licenseKey);
  print('=================================');
}
