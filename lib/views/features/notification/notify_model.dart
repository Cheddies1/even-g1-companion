import 'dart:convert';

class NotifyModel {
  final int msgId;
  final String appIdentifier;
  final String title;
  final String subTitle;
  final String message;
  final int timestamp;
  final String displayName;

  NotifyModel(
    this.msgId,
    this.appIdentifier,
    this.title,
    this.subTitle,
    this.message,
    this.timestamp,
    this.displayName,
  );

  static NotifyModel? fromJson(String data) {
    try {
      final json = jsonDecode(data);
      final msgId = json["msg_id"] as int? ?? 0;
      final appIdentifier = json["app_identifier"] as String? ?? "";
      final title = json["title"] as String? ?? "";
      final subTitle = json["subtitle"] as String? ?? "";
      final message = json["message"] as String? ?? "";
      final timestamp = json["time_s"] as int? ?? 0;
      final displayName = json["display_name"] as String? ?? "";
      return NotifyModel(msgId, appIdentifier, title, subTitle, message,
          timestamp, displayName);
    } catch (e) {
      return null;
    }
  }

  Map<String, dynamic> toMap() => {
        "msg_id": msgId,
        "app_identifier": appIdentifier,
        "title": title,
        "subtitle": subTitle,
        "message": message,
        "time_s": timestamp,
        "display_name": displayName,
      };

  String toJson() => jsonEncode(toMap());
}

class NotifyWhitelistModel {
  final List<NotifyAppModel> apps;

  NotifyWhitelistModel(this.apps);

  static NotifyWhitelistModel? fromJson(String data) {
    try {
      final json = jsonDecode(data);
      final apps = (json as List? ?? [])
          .map((app) => NotifyAppModel.fromMap(app))
          .toList();
      return NotifyWhitelistModel(apps);
    } catch (e) {
      return null;
    }
  }

  List<Map<String, dynamic>> toShowMap() => apps.map((app) => app.toMap()).toList();

  Map<String, dynamic> toMap() => {
        "calendar_enable": false,
        "call_enable": false,
        "msg_enable": false,
        "ios_mail_enable": false,
        "app": {
          "list": apps.map((app) => app.toMap()).toList(),
          "enable": true,
        }
      };

  String toJson() => jsonEncode(toMap());

  String toShowJson() => jsonEncode(toShowMap());
}

class NotifyAppModel {
  final String identifier;
  final String displayName;
  NotifyAppModel(
    this.identifier,
    this.displayName,
  );

  static NotifyAppModel fromMap(Map map) {
    final id = map["id"] as String? ?? "";
    final name = map["name"] as String? ?? "";
    return NotifyAppModel(id, name);
  }

  static NotifyAppModel? fromJson(String data) {
    try {
      final json = jsonDecode(data);
      final id = json["id"] as String? ?? "";
      final name = json["name"] as String? ?? "";
      return NotifyAppModel(id, name);
    } catch (e) {
      return null;
    }
  }

  Map<String, String> toMap() => {
        "id": identifier,
        "name": displayName,
      };

  String toJson() => jsonEncode(toMap());
}
