class Customer {
  String mobile;
  String custName;
  String yesNo;
  String status;
  String imagePath;
  String message;
  String vouchDate;
  String custNo;
  String billNo;
  String billAmount;
  String clBalance;
  String cmCode;
  String cmName;
  String monthNm;
  String sentTime;
  String lastError;

  // New Payment Fields
  String paymentStatus;
  String amountPaid;
  String transactionId;
  String paymentMethod;
  String receiptStatus;
  String paymentDate;

  String get resolvedImagePath {
    if (imagePath.isEmpty) return '';
    if (imagePath.startsWith('/')) return imagePath;
    if (imagePath.startsWith('VendSoft/')) {
      return '/storage/emulated/0/$imagePath';
    }
    return '/storage/emulated/0/VendSoft/$imagePath';
  }

  Customer({
    required this.mobile,
    this.custName = '',
    this.yesNo = '',
    required this.status,
    required this.imagePath,
    this.message = '',
    this.vouchDate = '',
    this.custNo = '',
    this.billNo = '',
    this.billAmount = '',
    this.clBalance = '',
    this.cmCode = '',
    this.cmName = '',
    this.monthNm = '',
    this.sentTime = '',
    this.lastError = '',
    this.paymentStatus = '',
    this.amountPaid = '',
    this.transactionId = '',
    this.paymentMethod = '',
    this.receiptStatus = '',
    this.paymentDate = '',
  });

  static String _extractCellString(dynamic cell) {
    if (cell == null) return '';
    if (cell is String) {
      if (cell == 'null') return '';
      return cell.trim();
    }
    try {
      final val = (cell as dynamic).value;
      if (val == null) return '';
      final str = val.toString();
      if (str == 'null') return '';
      return str.trim();
    } catch (_) {
      final str = cell.toString();
      if (str == 'null') return '';
      return str.trim();
    }
  }

  factory Customer.fromRow(List<dynamic> row) {
    return Customer(
      mobile: row.isNotEmpty ? _extractCellString(row[0]) : '',
      custName: row.length > 1 ? _extractCellString(row[1]) : '',
      yesNo: row.length > 2 ? _extractCellString(row[2]) : '',
      status: row.length > 3 ? _extractCellString(row[3]) : '',
      imagePath: row.length > 4 ? _extractCellString(row[4]) : '',
      message: row.length > 5 ? _extractCellString(row[5]) : '',
      vouchDate: row.length > 6 ? _extractCellString(row[6]) : '',
      custNo: row.length > 7 ? _extractCellString(row[7]) : '',
      billNo: row.length > 8 ? _extractCellString(row[8]) : '',
      billAmount: row.length > 9 ? _extractCellString(row[9]) : '',
      clBalance: row.length > 10 ? _extractCellString(row[10]) : '',
      cmCode: row.length > 11 ? _extractCellString(row[11]) : '',
      cmName: row.length > 12 ? _extractCellString(row[12]) : '',
      monthNm: row.length > 13 ? _extractCellString(row[13]) : '',
      sentTime: row.length > 14 ? _extractCellString(row[14]) : '',
      paymentStatus: row.length > 15 ? _extractCellString(row[15]) : '',
      amountPaid: row.length > 16 ? _extractCellString(row[16]) : '',
      transactionId: row.length > 17 ? _extractCellString(row[17]) : '',
      paymentMethod: row.length > 18 ? _extractCellString(row[18]) : '',
      receiptStatus: row.length > 19 ? _extractCellString(row[19]) : '',
      paymentDate: row.length > 20 ? _extractCellString(row[20]) : '',
    );
  }

  factory Customer.fromJson(Map<String, dynamic> json) {
    return Customer(
      mobile: json['mobile']?.toString() ?? '',
      custName: json['custName']?.toString() ?? '',
      yesNo: json['yesNo']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      imagePath: json['imagePath']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      vouchDate: json['vouchDate']?.toString() ?? '',
      custNo: json['custNo']?.toString() ?? '',
      billNo: json['billNo']?.toString() ?? '',
      billAmount: json['billAmount']?.toString() ?? '',
      clBalance: json['clBalance']?.toString() ?? '',
      cmCode: json['cmCode']?.toString() ?? '',
      cmName: json['cmName']?.toString() ?? '',
      monthNm: json['monthNm']?.toString() ?? '',
      sentTime: json['sentTime']?.toString() ?? '',
      lastError: json['lastError']?.toString() ?? '',
      paymentStatus: json['paymentStatus']?.toString() ?? '',
      amountPaid: json['amountPaid']?.toString() ?? '',
      transactionId: json['transactionId']?.toString() ?? '',
      paymentMethod: json['paymentMethod']?.toString() ?? '',
      receiptStatus: json['receiptStatus']?.toString() ?? '',
      paymentDate: json['paymentDate']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mobile': mobile,
      'custName': custName,
      'yesNo': yesNo,
      'status': status,
      'imagePath': imagePath,
      'message': message,
      'vouchDate': vouchDate,
      'custNo': custNo,
      'billNo': billNo,
      'billAmount': billAmount,
      'clBalance': clBalance,
      'cmCode': cmCode,
      'cmName': cmName,
      'monthNm': monthNm,
      'sentTime': sentTime,
      'lastError': lastError,
      'paymentStatus': paymentStatus,
      'amountPaid': amountPaid,
      'transactionId': transactionId,
      'paymentMethod': paymentMethod,
      'receiptStatus': receiptStatus,
      'paymentDate': paymentDate,
    };
  }

  List<String> toRow() {

    return [
      mobile,
      custName,
      yesNo,
      status,
      imagePath,
      message,
      vouchDate,
      custNo,
      billNo,
      billAmount,
      clBalance,
      cmCode,
      cmName,
      monthNm,
      sentTime,
      paymentStatus,
      amountPaid,
      transactionId,
      paymentMethod,
      receiptStatus,
      paymentDate,
    ];
  }
}