import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'search_controller.dart';
import 'search_recovery_actions.dart';

class SearchAllView extends StatelessWidget {
  final AppSearchController controller;
  const SearchAllView({required this.controller, super.key});

  @override
  Widget build(BuildContext context) => Obx(() => ListView(
        key: const PageStorageKey('search-all'),
        padding: const EdgeInsets.all(12),
        children: !controller.submitted.value
            ? [
                const ListTile(
                    title: Text('一次搜索，查找所有平台'),
                    subtitle: Text('也可以粘贴直播链接，或输入房间号直接进入')),
                if (controller.history.isNotEmpty) ...[
                  ListTile(
                      title: const Text('最近搜索'),
                      trailing: TextButton(
                          onPressed: controller.clearHistory,
                          child: const Text('清空'))),
                  Wrap(
                      spacing: 8,
                      children: controller.history
                          .map((text) => ActionChip(
                              label: Text(text),
                              onPressed: () => controller.useHistory(text)))
                          .toList()),
                ],
              ]
            : controller.sites.map((site) => _section(context, site)).toList(),
      ));

  Widget _section(BuildContext context, Site site) => Obx(() {
        final results = controller.results(site);
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                  leading: Image.asset(site.logo, width: 24),
                  title: Text(site.name),
                  trailing: TextButton(
                      onPressed: () => controller.tabController
                          .animateTo(controller.sites.indexOf(site) + 1),
                      child: const Text('查看全部'))),
              if (results.pageLoadding.value)
                const LinearProgressIndicator()
              else if (results.pageError.value)
                ListTile(
                    title: Text(results.errorMsg.value),
                    trailing: TextButton(
                        onPressed: results.refreshData,
                        child: const Text('重试')))
              else if (results.list.isEmpty)
                const ListTile(title: Text('没有找到相关结果'))
              else if (results.searchMode.value == 1)
                ...results.list
                    .take(5)
                    .cast<LiveAnchorItem>()
                    .map((item) => ListTile(
                          leading: NetImage(item.avatar,
                              width: 40, height: 40, borderRadius: 20),
                          title: Text(item.userName),
                          subtitle: Text(item.liveStatus ? '直播中' : '未开播'),
                          onTap: () => AppNavigator.toLiveRoomDetail(
                              site: site, roomId: item.roomId),
                        ))
              else
                LayoutBuilder(builder: (context, constraints) {
                  final columns =
                      (constraints.maxWidth / 220).floor().clamp(1, 4);
                  return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: results.list
                          .take(4)
                          .cast<LiveRoomItem>()
                          .map((item) => SizedBox(
                              width:
                                  (constraints.maxWidth - (columns - 1) * 12) /
                                      columns,
                              child: LiveRoomCard(site, item)))
                          .toList());
                }),
              if (site.id == 'douyin' && results.pageError.value)
                SearchRecoveryActions(
                    keyword: results.keyword,
                    anchors: results.searchMode.value == 1),
              const SizedBox(height: 16),
            ]);
      });
}
