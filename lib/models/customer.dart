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
    required this.sentTime,
    this.lastError = '',
    this.paymentStatus = '',
    this.amountPaid = '',
    this.transactionId = '',
    this.paymentMethod = '',
    this.receiptStatus = '',
    this.paymentDate = '',
  });

  factory Customer.fromRow(List<dynamic> row) {
    return Customer(
      mobile: row.isNotEmpty ? row[0]?.toString() ?? '' : '',
      custName: row.length > 1 ? row[1]?.toString() ?? '' : '',
      yesNo: row.length > 2 ? row[2]?.toString() ?? '' : '',
      status: row.length > 3 ? row[3]?.toString() ?? '' : '',
      imagePath: row.length > 4 ? row[4]?.toString() ?? '' : '',
      message: row.length > 5 ? row[5]?.toString() ?? '' : '',
      vouchDate: row.length > 6 ? row[6]?.toString() ?? '' : '',
      custNo: row.length > 7 ? row[7]?.toString() ?? '' : '',
      billNo: row.length > 8 ? row[8]?.toString() ?? '' : '',
      billAmount: row.length > 9 ? row[9]?.toString() ?? '' : '',
      clBalance: row.length > 10 ? row[10]?.toString() ?? '' : '',
      cmCode: row.length > 11 ? row[11]?.toString() ?? '' : '',
      cmName: row.length > 12 ? row[12]?.toString() ?? '' : '',
      monthNm: row.length > 13 ? row[13]?.toString() ?? '' : '',
      sentTime: row.length > 14 ? row[14]?.toString() ?? '' : '',
      paymentStatus: (row.length > 15 && row[15]?.value != null) ? row[15]!.value.toString().trim() : '',
      amountPaid: (row.length > 16 && row[16]?.value != null) ? row[16]!.value.toString().trim() : '',
      transactionId: (row.length > 17 && row[17]?.value != null) ? row[17]!.value.toString().trim() : '',
      paymentMethod: (row.length > 18 && row[18]?.value != null) ? row[18]!.value.toString().trim() : '',
      receiptStatus: (row.length > 19 && row[19]?.value != null) ? row[19]!.value.toString().trim() : '',
      paymentDate: (row.length > 20 && row[20]?.value != null) ? row[20]!.value.toString().trim() : '',
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