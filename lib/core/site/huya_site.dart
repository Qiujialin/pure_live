import 'dart:convert';
import 'dart:developer';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:pure_live/common/index.dart';
import 'package:http/http.dart' as http;
import 'package:tars_dart/tars/net/base_tars_http.dart';

import '../danmaku/huya_danmaku.dart';
import '../interface/live_danmaku.dart';
import '../interface/live_site.dart';
import '../tars/huya_user_id.dart';
import '../tars/get_cdn_token_ex_req.dart';
import '../tars/get_cdn_token_ex_resp.dart';

class HuyaSite implements LiveSite {
  @override
  String id = 'huya';

  @override
  String name = '虎牙';

  @override
  LiveDanmaku getDanmaku() => HuyaDanmaku();

  // WUP2 鉴权相关常量和客户端
  static const String HYSDK_UA =
      "HYSDK(Windows, 30000002)_APP(pc_exe&7060000&official)_SDK(trans&2.32.3.5646)";
  static const String baseUrl = "https://m.huya.com/";
  static Map<String, String> requestHeaders = {
    'Origin': baseUrl,
    'Referer': baseUrl,
    'User-Agent': HYSDK_UA
  };
  final BaseTarsHttp tupClient = BaseTarsHttp(
    "http://wup.huya.com",
    "liveui",
    headers: requestHeaders,
  );

  static Future<dynamic> _getJson(String url) async {
    var resp = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 12_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'
      },
    );
    return await jsonDecode(resp.body);
  }

  @override
  Future<Map<String, List<String>>> getLiveStream(LiveRoom room) async {
    Map<String, List<String>> links = {};

    String url = 'https://mp.huya.com/cache.php?m=Live'
        '&do=profileRoom&roomid=${room.roomId}';

    try {
      dynamic response = await _getJson(url);
      if (response['status'] == 200) {
        Map data = response['data']['stream']['flv'];

        // 获取 baseSteamInfoList 用于 WUP2 鉴权
        List<dynamic> baseSteamInfoList =
            response['data']['stream']['baseSteamInfoList'] ?? [];

        // 获取支持的分辨率
        Map<String, String> rates = {};
        for (var rate in data['rateArray']) {
          String bitrate = rate['iBitRate'].toString();
          rates[rate['sDisplayName']] = '_$bitrate';
        }

        // 获取支持的线路
        links['原画'] = [];
        for (var item in data['multiLine']) {
          String cdnType = item['cdnType']?.toString() ?? '';

          // 从 baseSteamInfoList 中查找对应的流信息
          var streamInfo = baseSteamInfoList.firstWhere(
            (e) => e['sCdnType'] == cdnType,
            orElse: () => null,
          );

          if (streamInfo != null) {
            String streamName = streamInfo['sStreamName']?.toString() ?? '';
            String sFlvUrl = streamInfo['sFlvUrl']?.toString() ?? '';
            int presenterUid = 0;

            // 获取 presenterUid (lChannelId)
            var lChannelId = streamInfo['lChannelId'];
            if (lChannelId is String) {
              presenterUid = int.tryParse(lChannelId) ?? 0;
            } else if (lChannelId is int) {
              presenterUid = lChannelId;
            }

            if (streamName.isNotEmpty && sFlvUrl.isNotEmpty) {
              try {
                // 通过 WUP2 获取 token
                String antiCode = await getCdnTokenInfoEx(streamName);
                // 构建签名后的 antiCode
                antiCode = buildAntiCode(streamName, presenterUid, antiCode);
                // 构建最终 URL
                String finalUrl =
                    '$sFlvUrl/$streamName.flv?$antiCode&codec=264';
                finalUrl = finalUrl.replaceAll('http://', 'https://');

                links['原画']?.add(finalUrl);

                // 添加其他清晰度
                for (var name in rates.keys) {
                  links[name] ??= [];
                  String rateUrl =
                      '$sFlvUrl/$streamName${rates[name]}.flv?$antiCode&codec=264';
                  rateUrl = rateUrl.replaceAll('http://', 'https://');
                  links[name]?.add(rateUrl);
                }
              } catch (e) {
                log('WUP2 token error for $cdnType: $e',
                    name: 'HuyaApi.getLiveStream');
              }
            }
          }
        }
      }
    } catch (e) {
      log(e.toString(), name: 'HuyaApi.getRoomStreamLink');
      return links;
    }
    return links;
  }

  @override
  Future<LiveRoom> getRoomInfo(LiveRoom room) async {
    String url = 'https://mp.huya.com/cache.php?m=Live'
        '&do=profileRoom&roomid=${room.roomId}';

    try {
      dynamic response = await _getJson(url);
      if (response['status'] == 200) {
        dynamic data = response['data'];

        room.platform = 'huya';
        room.userId = data['profileInfo']?['uid']?.toString() ?? '';
        room.nick = data['profileInfo']?['nick'] ?? '';
        room.title = data['liveData']?['introduction'] ?? '';
        room.cover = data['liveData']?['screenshot'] ?? '';
        room.avatar = data['profileInfo']?['avatar180'] ?? '';
        room.area = data['liveData']?['gameFullName'] ?? '';
        room.watching = data['liveData']?['attendeeCount']?.toString() ?? '';
        room.followers = data['liveData']?['totalCount']?.toString() ?? '';

        final liveStatus = data['liveStatus'] ?? 'OFF';
        if (liveStatus == 'OFF' || liveStatus == 'FREEZE') {
          room.liveStatus = LiveStatus.offline;
        } else if (liveStatus == 'REPLAY') {
          room.liveStatus = LiveStatus.replay;
        } else {
          room.liveStatus = LiveStatus.live;
        }
      }
    } catch (e) {
      log(e.toString(), name: 'HuyaApi.getRoomInfo');
      return room;
    }
    return room;
  }

  @override
  Future<List<LiveRoom>> getRecommend({int page = 1, int size = 20}) async {
    List<LiveRoom> list = [];

    page--;
    int realPage = page ~/ 6 + 1;
    if (size == 10) realPage = page ~/ 12 + 1;
    String url = 'https://www.huya.com/cache.php?m=LiveList'
        '&do=getLiveListByPage&tagAll=0&page=$realPage';

    try {
      dynamic response = await _getJson(url);
      if (response['status'] == 200) {
        List<dynamic> roomInfoList = response['data']['datas'];
        for (var roomInfo in roomInfoList) {
          LiveRoom room = LiveRoom(roomInfo['profileRoom'].toString());
          room.platform = 'huya';
          room.userId = roomInfo['uid']?.toString() ?? '';
          room.nick = roomInfo['nick'] ?? '';
          room.title = roomInfo['introduction'] ?? '';
          room.cover = roomInfo['screenshot'] ?? '';
          room.avatar = roomInfo['avatar180'] ?? '';
          room.area = roomInfo['gameFullName'] ?? '';
          room.followers = roomInfo['totalCount'] ?? '';
          room.liveStatus = LiveStatus.live;
          list.add(room);
        }
      }
    } catch (e) {
      log(e.toString(), name: 'HuyaApi.getRecommend');
      return list;
    }
    return list;
  }

  @override
  Future<List<List<LiveArea>>> getAreaList() async {
    List<List<LiveArea>> areaList = [];
    String url =
        'https://m.huya.com/cache.php?m=Game&do=ajaxGameList&bussType=';

    final areas = {
      '1': '网游竞技',
      '2': '单机热游',
      '3': '手游休闲',
      '8': '娱乐天地',
    };
    try {
      for (var typeId in areas.keys) {
        String typeName = areas[typeId]!;
        dynamic response = await _getJson(url + typeId);
        List<LiveArea> subAreaList = [];
        List<dynamic> areaInfoList = response['gameList'];
        for (var areaInfo in areaInfoList) {
          LiveArea area = LiveArea();
          area.platform = 'huya';
          area.areaType = typeId;
          area.typeName = typeName;
          area.areaId = areaInfo['gid']?.toString() ?? '';
          area.areaName = areaInfo['gameFullName'] ?? '';
          area.areaPic =
              'https://huyaimg.msstatic.com/cdnimage/game/${area.areaId}-MS.jpg';
          subAreaList.add(area);
        }
        areaList.add(subAreaList);
      }
    } catch (e) {
      log(e.toString(), name: 'HuyaApi.getAreaList');
      return areaList;
    }
    return areaList;
  }

  @override
  Future<List<LiveRoom>> getAreaRooms(LiveArea area,
      {int page = 1, int size = 20}) async {
    List<LiveRoom> list = [];

    page--;
    int realPage = page ~/ 6 + 1;
    if (size == 10) realPage = page ~/ 12 + 1;
    String url = 'https://www.huya.com/cache.php?m=LiveList'
        '&do=getLiveListByPage&gameId=${area.areaId}&tagAll=0&page=$realPage';

    try {
      dynamic response = await _getJson(url);
      if (response['status'] == 200) {
        List<dynamic> roomInfoList = response['data']['datas'];
        for (var roomInfo in roomInfoList) {
          LiveRoom room = LiveRoom(roomInfo['profileRoom'].toString());
          room.platform = 'huya';
          room.userId = roomInfo['uid'] ?? '';
          room.nick = roomInfo['nick'] ?? '';
          room.title = roomInfo['introduction'] ?? '';
          room.cover = roomInfo['screenshot'] ?? '';
          room.avatar = roomInfo['avatar180'] ?? '';
          room.area = roomInfo['gameFullName'] ?? '';
          room.followers = roomInfo['totalCount'] ?? '';
          room.liveStatus = LiveStatus.live;
          list.add(room);
        }
      }
    } catch (e) {
      log(e.toString(), name: 'HuyaApi.getAreaRooms');
      return list;
    }
    return list;
  }

  @override
  Future<List<LiveRoom>> search(String keyWords) async {
    List<LiveRoom> list = [];
    String url = 'https://search.cdn.huya.com/?m=Search&do=getSearchContent&'
        'q=$keyWords&uid=0&v=4&typ=-5&livestate=0&rows=5&start=0';

    try {
      dynamic response = await _getJson(url);
      List<dynamic> ownerList = response['response']['1']['docs'];
      for (Map ownerInfo in ownerList) {
        LiveRoom owner = LiveRoom(ownerInfo['room_id'].toString());
        owner.platform = 'huya';
        owner.userId = ownerInfo['uid']?.toString() ?? '';
        owner.nick = ownerInfo['game_nick'] ?? '';
        owner.title = ownerInfo['live_intro'] ?? '';
        owner.area = ownerInfo['game_name'] ?? '';
        owner.avatar = ownerInfo['game_avatarUrl52'] ?? '';
        owner.followers = ownerInfo['game_activityCount']?.toString() ?? '';
        owner.liveStatus = (ownerInfo['gameLiveOn'] ?? false)
            ? LiveStatus.live
            : LiveStatus.offline;
        list.add(owner);
      }
    } catch (e) {
      log(e.toString(), name: 'HuyaApi.search');
      return list;
    }
    return list;
  }

  /// 通过 WUP2 协议获取 CDN Token
  Future<String> getCdnTokenInfoEx(String stream) async {
    var func = "getCdnTokenInfoEx";
    var tid = HuyaUserId();
    tid.sHuYaUA = "pc_exe&7060000&official";
    var tReq = GetCdnTokenExReq();
    tReq.tId = tid;
    tReq.sStreamName = stream;
    var resp = await tupClient.tupRequest(func, tReq, GetCdnTokenExResp());
    return resp.sFlvToken;
  }

  /// 构建 antiCode 签名
  /// [stream] streamName
  /// [presenterUid] 主播 UID (lChannelId)
  /// [antiCode] 从 WUP2 获取的原始 token
  String buildAntiCode(String stream, int presenterUid, String antiCode) {
    var mapAnti = Uri(query: antiCode).queryParametersAll;
    if (!mapAnti.containsKey("fm")) {
      return antiCode;
    }

    var ctype = mapAnti["ctype"]?.first ?? "huya_pc_exe";
    var platformId = int.tryParse(mapAnti["t"]?.first ?? "0");

    bool isWap = platformId == 103;
    var clacStartTime = DateTime.now().millisecondsSinceEpoch;

    // 计算 seqId
    var seqId = presenterUid + clacStartTime;

    // 计算 secretHash = MD5(seqId|ctype|platformId)
    final secretHash =
        md5.convert(utf8.encode('$seqId|$ctype|$platformId')).toString();

    // rotl64 位旋转
    final convertUid = rotl64(presenterUid);
    final calcUid = isWap ? presenterUid : convertUid;

    // 解码 fm 获取 secretPrefix
    final fm = Uri.decodeComponent(mapAnti['fm']!.first);
    final secretPrefix = utf8.decode(base64.decode(fm)).split('_').first;
    var wsTime = mapAnti['wsTime']!.first;

    // 计算 wsSecret
    final secretStr =
        '${secretPrefix}_${calcUid}_${stream}_${secretHash}_$wsTime';
    final wsSecret = md5.convert(utf8.encode(secretStr)).toString();

    // 生成 UUID
    final rnd = Random();
    final ct =
        ((int.parse(wsTime, radix: 16) + rnd.nextDouble()) * 1000).toInt();
    final uuid =
        (((ct % 1e10) + rnd.nextDouble()) * 1e3 % 0xffffffff).toInt().toString();

    // 组装结果
    final Map<String, dynamic> antiCodeRes = {
      'wsSecret': wsSecret,
      'wsTime': wsTime,
      'seqid': seqId,
      'ctype': ctype,
      'ver': '1',
      'fs': mapAnti['fs']!.first,
      'fm': Uri.encodeComponent(mapAnti['fm']!.first),
      't': platformId,
    };
    if (isWap) {
      antiCodeRes.addAll({'uid': presenterUid, 'uuid': uuid});
    } else {
      antiCodeRes['u'] = convertUid;
    }

    return antiCodeRes.entries.map((e) => '${e.key}=${e.value}').join('&');
  }

  /// 64位左旋转
  int rotl64(int t) {
    final low = t & 0xFFFFFFFF;
    final rotatedLow = ((low << 8) | (low >> 24)) & 0xFFFFFFFF;
    final high = t & ~0xFFFFFFFF;
    return high | rotatedLow;
  }
}
