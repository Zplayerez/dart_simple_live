import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/modules/account/account_page.dart';

class SettingsController extends BaseController
    with GetTickerProviderStateMixin {
  late TabController tabController;
  var tabIndex = 0.obs;

  SettingsController() {
    tabController = TabController(length: 5, vsync: this);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (tabIndex.value == currentIndex) {
        return;
      }
      tabIndex.value = currentIndex;
      if (tabIndex.value == 0) {
        hardwareDecodeFocusNode.requestFocus();
      }
      if (tabIndex.value == 1) {
        danmakuFoucsNode.requestFocus();
      }
      if (tabIndex.value == 2) {
        autoUpdateFollowEnableFocusNode.requestFocus();
      }
      if (tabIndex.value == 3) {
        bilibiliFoucsNode.requestFocus();
      }
      if (tabIndex.value == 4) {
        versionFocusNode.requestFocus();
      }
    });
  }
  var hardwareDecodeFocusNode = AppFocusNode()..isFoucsed.value = true;
  var compatibleModeFocusNode = AppFocusNode();
  var scaleFoucsNode = AppFocusNode();
  var defaultQualityFocusNode = AppFocusNode();
  var danmakuFoucsNode = AppFocusNode();
  var danmakuSizeFoucsNode = AppFocusNode();
  var danmakuSpeedFoucsNode = AppFocusNode();
  var danmakuAreaFoucsNode = AppFocusNode();
  var danmakuOpacityFoucsNode = AppFocusNode();
  var danmakuStorkeFoucsNode = AppFocusNode();

  var autoUpdateFollowEnableFocusNode = AppFocusNode();
  var autoUpdateFollowDurationFocusNode = AppFocusNode();
  var updateFollowThreadFocusNode = AppFocusNode();

  var bilibiliFoucsNode = AppFocusNode();
  var versionFocusNode = AppFocusNode();
  final douyuFocusNode = AppFocusNode();
  final huyaFocusNode = AppFocusNode();
  final douyinFocusNode = AppFocusNode();

  AppFocusNode accountFocusNode(String siteId) => switch (siteId) {
        'douyu' => douyuFocusNode,
        'huya' => huyaFocusNode,
        'douyin' => douyinFocusNode,
        _ => bilibiliFoucsNode,
      };

  Future<void> openAccount(String siteId) async {
    await Get.to(() => AccountPage(siteId: siteId));
    if (!isClosed) accountFocusNode(siteId).requestFocus();
  }

  @override
  void onClose() {
    tabController.dispose();
    for (final node in [
      hardwareDecodeFocusNode,
      compatibleModeFocusNode,
      scaleFoucsNode,
      defaultQualityFocusNode,
      danmakuFoucsNode,
      danmakuSizeFoucsNode,
      danmakuSpeedFoucsNode,
      danmakuAreaFoucsNode,
      danmakuOpacityFoucsNode,
      danmakuStorkeFoucsNode,
      autoUpdateFollowEnableFocusNode,
      autoUpdateFollowDurationFocusNode,
      updateFollowThreadFocusNode,
      bilibiliFoucsNode,
      douyuFocusNode,
      huyaFocusNode,
      douyinFocusNode,
      versionFocusNode,
    ]) {
      node.dispose();
    }
    super.onClose();
  }
}
