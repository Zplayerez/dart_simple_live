import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/room_input_parser.dart';

class AppSearchController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late final TabController tabController;
  late final List<Site> sites;
  int index = 0;
  final searchMode = 0.obs;
  final submitted = false.obs;
  final parsing = false.obs;
  final history = <String>[].obs;
  final searchController = TextEditingController();
  int _submission = 0;

  SearchListController results(Site site) =>
      Get.find<SearchListController>(tag: site.id);

  @override
  void onInit() {
    super.onInit();
    sites = Sites.supportSites;
    for (final site in sites) {
      Get.put(SearchListController(site), tag: site.id);
    }
    history.assignAll(LocalStorageService.instance
        .getValue<List>('SearchHistory', []).whereType<String>());
    tabController = TabController(length: sites.length + 1, vsync: this);
    tabController.addListener(() {
      if (index == tabController.index) return;
      index = tabController.index;
      _loadVisible();
    });
  }

  void _loadVisible() {
    final visible = index == 0 ? sites : [sites[index - 1]];
    for (final site in visible) {
      final controller = results(site);
      if (controller.keyword.isNotEmpty &&
          controller.currentPage == 1 &&
          !controller.loadding &&
          !controller.pageError.value) {
        unawaited(controller.loadData());
      }
    }
  }

  Future<void> doSearch() async {
    final text = searchController.text.trim();
    final submission = ++_submission;
    if (text.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (text.contains(RegExp(r'https?://')) ||
        (searchMode.value == 0 && RegExp(r'^\d+$').hasMatch(text))) {
      parsing.value = true;
      try {
        ParsedRoom? room;
        if (RegExp(r'^\d+$').hasMatch(text)) {
          final Site? site = index == 0
              ? await Get.dialog<Site>(SimpleDialog(
                  title: const Text('选择房间所属平台'),
                  children: sites
                      .map((site) => SimpleDialogOption(
                          onPressed: () => Get.back(result: site),
                          child: Text(site.name)))
                      .toList(),
                ))
              : sites[index - 1];
          if (site != null) room = ParsedRoom(site.id, text);
        } else {
          room = await RoomInputParser.parse(text);
          if (room == null) SmartDialog.showToast('未识别到直播链接，请检查链接是否完整');
        }
        if (!isClosed && submission == _submission && room != null) {
          AppNavigator.toLiveRoomDetail(
              site: Sites.allSites[room.siteId]!, roomId: room.roomId);
        }
      } catch (_) {
        if (!isClosed && submission == _submission) {
          SmartDialog.showToast('链接暂时无法解析，请重试');
        }
      } finally {
        if (!isClosed && submission == _submission) parsing.value = false;
      }
      return;
    }
    parsing.value = false;
    submitted.value = true;
    history.remove(text);
    history.insert(0, text);
    if (history.length > 12) history.removeRange(12, history.length);
    unawaited(LocalStorageService.instance
        .setValue('SearchHistory', history.toList()));
    for (final site in sites) {
      final controller = results(site);
      controller.clear();
      controller.keyword = text;
      controller.searchMode.value = searchMode.value;
    }
    _loadVisible();
  }

  void useHistory(String text) {
    searchController.text = text;
    doSearch();
  }

  void clearHistory() {
    history.clear();
    LocalStorageService.instance.removeValue('SearchHistory');
  }

  @override
  void onClose() {
    _submission++;
    tabController.dispose();
    searchController.dispose();
    for (final site in sites) {
      Get.delete<SearchListController>(tag: site.id);
    }
    super.onClose();
  }
}
