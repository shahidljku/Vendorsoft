// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:encrypt/encrypt.dart';
// ignore: depend_on_referenced_packages
import 'package:pointycastle/asymmetric/api.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Usage: dart keygen.dart [-k <path/to/private.pem>] <Device ID> [Customer/Company Name]');
    return;
  }

  String? customKeyPath;
  final positionalArgs = <String>[];

  for (int i = 0; i < args.length; i++) {
    if ((args[i] == '-k' || args[i] == '--key') && i + 1 < args.length) {
      customKeyPath = args[i + 1];
      i++;
    } else if (args[i].startsWith('--key=')) {
      customKeyPath = args[i].substring('--key='.length);
    } else {
      positionalArgs.add(args[i]);
    }
  }

  if (positionalArgs.isEmpty) {
    print('Usage: dart keygen.dart [-k <path/to/private.pem>] <Device ID> [Customer/Company Name]');
    return;
  }

  final deviceId = positionalArgs[0];
  final companyName = positionalArgs.length > 1 ? positionalArgs[1] : 'Unknown Customer';

  // Determine key path: Priority 1: Command-line flag -> Priority 2: Environment variable -> Priority 3: Default permanent secure location
  final possiblePaths = <String>[
    if (customKeyPath != null && customKeyPath.isNotEmpty) customKeyPath,
    if (Platform.environment['RSA_PRIVATE_KEY_PATH'] != null && Platform.environment['RSA_PRIVATE_KEY_PATH']!.isNotEmpty)
      Platform.environment['RSA_PRIVATE_KEY_PATH']!,
    if (Platform.environment['PRIVATE_KEY_PATH'] != null && Platform.environment['PRIVATE_KEY_PATH']!.isNotEmpty)
      Platform.environment['PRIVATE_KEY_PATH']!,
    r'D:\VendorSoft_Secrets\RSA Keys\private.pem',
  ];

  File? keyFile;
  for (final path in possiblePaths) {
    final file = File(path);
    if (file.existsSync()) {
      keyFile = file;
      break;
    }
  }

  if (keyFile == null) {
    print('Error: RSA private key file not found.');
    print('Searched paths: ${possiblePaths.join(', ')}');
    print('Please specify the path using -k/--key <path_to_pem_file> or set the RSA_PRIVATE_KEY_PATH environment variable.');
    exit(1);
  }

  final privateKeyString = keyFile.readAsStringSync();

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
