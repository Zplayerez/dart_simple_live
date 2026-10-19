import 'dart:io';

/// Old clients put all interface addresses in one semicolon-separated QR code.
/// Keep each address and explicit port intact when connecting to those clients.
List<Uri> parseLocalSyncAddresses(String input) {
  final result = <Uri>[];
  for (final part in input.split(';')) {
    final text = part.trim();
    if (text.isEmpty) continue;
    final literal = InternetAddress.tryParse(text);
    final uri = literal != null
        ? Uri(scheme: 'http', host: literal.address, port: 23234)
        : Uri.tryParse(text.contains('://') ? text : 'http://$text');
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        InternetAddress.tryParse(uri.host) == null ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('请输入设备显示的 IP 地址或 IP:端口');
    }
    final endpoint = uri.hasPort ? uri : uri.replace(port: 23234);
    if (!result.contains(endpoint)) result.add(endpoint);
  }
  if (result.isEmpty) throw const FormatException('请输入设备地址');
  return result;
}
