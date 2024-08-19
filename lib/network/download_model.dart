import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/translations.dart';
import '../base.dart';
import 'app_dio.dart';
import 'download.dart';

abstract class DownloadedItem{
  ///漫画源
  DownloadType get type;
  ///漫画名
  String get name;
  ///章节
  List<String> get eps;
  ///已下载的章节
  List<int> get downloadedEps;
  ///标识符
  String get id;
  ///副标题, 通常为作者
  String get subTitle;
  ///大小
  double? get comicSize;
  ///下载的时间
  DateTime? time;
  /// tags
  List<String> get tags;

  Map<String, dynamic> toJson();

  set comicSize(double? value);

  String? directory;
}

enum DownloadType{
  picacg, ehentai, jm, hitomi, htmanga, nhentai, other, favorite;

  ComicType toComicType() => switch(this){
    picacg => ComicType.picacg,
    ehentai => ComicType.ehentai,
    jm => ComicType.jm,
    hitomi => ComicType.hitomi,
    htmanga => ComicType.htManga,
    nhentai => ComicType.nhentai,
    other => ComicType.other,
    favorite => ComicType.other,
  };
}

typedef DownloadProgressCallback = void Function();

typedef DownloadProgressCallbackAsync = Future<void> Function();

abstract class DownloadingItem{
  ///完成时调用
  final DownloadProgressCallback? whenFinish;

  ///更新ui, 用于下载管理器页面
  DownloadProgressCallback? updateUi;

  ///出现错误时调用
  final DownloadProgressCallback? whenError;

  ///更新下载信息
  final DownloadProgressCallbackAsync? updateInfo;

  ///标识符, 对于哔咔和eh, 直接使用其提供的漫画id, 禁漫开头加jm, hitomi开头加hitomi
  final String id;

  ///类型
  DownloadType type;

  /// run function start will cause this increasing by 1
  ///
  /// this is used for preventing running multiple downloading function at the same time
  int _runtimeKey = 0;

  int _retryTimes = 0;

  String? directory;

  String get path {
    var downloadPath = DownloadManager().path!;
    return "$downloadPath/$directory";
  }

  /// headers for downloading cover
  Map<String, String> get headers => {};

  int _downloadedNum = 0;

  int _downloadingEp = 0;

  /// index of downloading episode
  ///
  /// Attention, this is used for array indexing, so it starts with 0
  int get downloadingEp => _downloadingEp;

  int index = 0;

  /// store all downloading stream
  ///
  /// when user click pause or stop button, stop all streams
  static List<StreamSubscription> streams = [];

  /// all image urls
  Map<int, List<String>>? links;

  String? get imageExtension => null;

  int get allowedLoadingNumbers => int.tryParse(appdata.settings[79]) ?? 6;

  DownloadingItem(this.whenFinish,this.whenError,this.updateInfo,this.id, {required this.type});

  Future<void> downloadCover() async{
    var file = File("$path/cover.jpg");
    if(file.existsSync()){
      return;
    }
    var dio = logDio();
    var res = await dio.get<Uint8List>(
        cover, options: Options(responseType: ResponseType.bytes, headers: headers));
    if(file.existsSync()){
      file.deleteSync();
    }
    file.createSync(recursive: true);
    file.writeAsBytesSync(res.data!);
  }

  /// retry when error
  Future<void> retry() async{
    _retryTimes++;
    if(_retryTimes > 4){
      whenError?.call();
      _retryTimes = 0;
    }else{
      await Future.delayed(Duration(seconds: 2 << _retryTimes));
      start();
    }
  }

  @mustCallSuper
  FutureOr<void> onStart(){
    if(directory == null) {
      directory = findValidFilename(DownloadManager().path!, title);
      Directory(directory!).createSync(recursive: true);
    }
  }

  /// begin or continue downloading
  void start() async{
    _runtimeKey++;
    var currentKey = _runtimeKey;
    try{
      await onStart();
      if(_runtimeKey != currentKey)  return;
      notifications.sendProgressNotification(downloadedPages, totalPages, "下载中".tl,
          "${downloadManager.downloading.length} Tasks");

      // get image links and cover
      links ??= await getLinks();
      await downloadCover();

      // download images
      while(_downloadingEp < links!.length && currentKey == _runtimeKey){
        int ep = links!.keys.elementAt(_downloadingEp);
        var urls = links![ep]!;
        while(index < urls.length && currentKey == _runtimeKey){
          notifications.sendProgressNotification(downloadedPages, totalPages, "下载中".tl,
              "${downloadManager.downloading.length} Tasks");
          for(int i=0; i<allowedLoadingNumbers; i++){
            if(index+i >= urls.length)  break;
            loadImageToCache(urls[index+i]);
          }
          var (bytes, ext) = await getImage(urls[index]);
          if(!ext.startsWith(".")){
            ext = ".$ext";
          }
          if(bytes.isEmpty){
            throw Exception("Fail to download image: data is empty.");
          }
          if(currentKey != _runtimeKey)  return;
          File file;
          if(haveEps) {
            file = File("$path/$ep/$index$ext");
          }else{
            file = File("$path/$index$ext");
          }
          if(await file.exists()){
            await file.delete();
          }
          await file.create(recursive: true);
          await file.writeAsBytes(bytes);
          index++;
          _downloadedNum++;
          updateUi?.call();
          await updateInfo?.call();
        }
        if(currentKey != _runtimeKey)  return;
        index = 0;
        _downloadingEp++;
        await updateInfo?.call();
      }

      // finish downloading
      if(DownloadManager().downloading.elementAtOrNull(0) != this) return;
      await onEnd();
      whenFinish?.call();
      stopAllStream();
    }
    catch(e, s){
      if(currentKey != _runtimeKey)  return;
      LogManager.addLog(LogLevel.error, "Download", "$e\n$s");
      retry();
    }
  }

  /// add a StreamSubscription to streams
  void addStreamSubscription(StreamSubscription stream){
    streams.add(stream);
    stream.onDone(() {
      streams.remove(stream);
    });
  }

  /// stop all streams
  void stopAllStream(){
    for(var s in streams){
      s.cancel();
    }
    streams.clear();
  }

  /// pause downloading
  void pause(){
    _runtimeKey++;
    notifications.endProgress();
    stopAllStream();
    ImageManager.clearTasks();
  }

  /// stop downloading
  void stop(){
    _runtimeKey++;
    stopAllStream();
    notifications.endProgress();
    if(downloadManager.isExists(id)) {
      if(links == null) return;
      var comicPath = "$path/";
      for(var ep in links!.keys.toList()){
        var directory = Directory(comicPath + ep.toString());
        if(directory.existsSync()){
          directory.deleteSync(recursive: true);
        }
      }
    } else {
      var file = Directory(path);
      if (file.existsSync()) {
        file.delete(recursive: true);
      }
    }
  }

  Map<String, dynamic> toBaseMap() {
    Map<String, List<String>>? convertedData;
    if(links != null){
      convertedData = {};
      links!.forEach((key, value) {
        convertedData![key.toString()] = value;
      });
    }

    return {
      "id": id,
      "type": type.index,
      "_downloadedNum": _downloadedNum,
      "_downloadingEp": _downloadingEp,
      "index": index,
      "links": convertedData,
      "directory": directory,
    };
  }

  Map<String, dynamic> toMap();

  DownloadingItem.fromMap(Map<String, dynamic> map, this.whenFinish,this.whenError,this.updateInfo):
      id = map["id"],
      type = DownloadType.values[map["type"]],
      _downloadedNum = map["_downloadedNum"],
      _downloadingEp = map["_downloadingEp"],
      index = map["index"],
      links = null{
    var data = map["links"] as Map<String, dynamic>?;
    if(data != null){
      links = {};
      data.forEach((key, value) {
        links![int.parse(key)] = List<String>.from(value);
      });
    }
    directory = map["directory"];
  }

  /// get all image links
  ///
  /// key - episode number(starts with 1), value - image links in this episode
  ///
  /// if platform don't have episode, this only have one key: 0.
  Future<Map<int, List<String>>> getLinks();

  /// whether this platform have episode
  bool get haveEps => type!=DownloadType.ehentai&&type!=DownloadType.hitomi&&
      type!=DownloadType.htmanga&&type!=DownloadType.nhentai;

  void loadImageToCache(String link);

  Future<(Uint8List data, String ext)> getImage(String link);

  ///获取封面链接
  String get cover;

  ///总共的图片数量
  int get totalPages => links?.totalLength ?? 0;

  ///已下载的图片数量
  int get downloadedPages => _downloadedNum;

  ///标题
  String get title;

  FutureOr<void> onEnd(){}

  @override
  bool operator==(Object other){
    if(other is DownloadingItem){
      return id == other.id;
    }else{
      return false;
    }
  }

  @override
  int get hashCode => id.hashCode;

  FutureOr<DownloadedItem> toDownloadedItem();
}