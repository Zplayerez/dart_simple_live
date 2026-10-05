import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/search/search_all_view.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_list_view.dart';

class SearchPage extends GetView<AppSearchController> {
  const SearchPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: TextField(
          controller: controller.searchController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: "主播名、直播链接或房间号",
            border: OutlineInputBorder(
              borderRadius: AppStyle.radius24,
            ),
            contentPadding: AppStyle.edgeInsetsH12,
            prefixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: Get.back,
                  icon: const Icon(Icons.arrow_back),
                ),
                Obx(
                  () => DropdownButton<int>(
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(
                        value: 0,
                        child: Text("房间"),
                      ),
                      DropdownMenuItem(
                        value: 1,
                        child: Text("主播"),
                      ),
                    ],
                    value: controller.searchMode.value,
                    onChanged: (e) {
                      controller.searchMode.value = e ?? 0;
                      controller.doSearch();
                    },
                  ),
                ),
                AppStyle.hGap8,
              ],
            ),
            suffixIcon: IconButton(
              onPressed: controller.doSearch,
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (e) {
            controller.doSearch();
          },
        ),
        bottom: TabBar(
          controller: controller.tabController,
          padding: EdgeInsets.zero,
          tabAlignment: TabAlignment.center,
          tabs: [
            const Tab(text: '全部平台'),
            ...controller.sites
                .map(
                  (e) => Tab(
                    //text: e.name,
                    child: Row(
                      children: [
                        Image.asset(
                          e.logo,
                          width: 24,
                        ),
                        AppStyle.hGap8,
                        Text(e.name),
                      ],
                    ),
                  ),
                )
                .toList()
          ],
          labelPadding: AppStyle.edgeInsetsH20,
          isScrollable: true,
          indicatorSize: TabBarIndicatorSize.label,
        ),
      ),
      body: Obx(() => Column(children: [
            if (controller.parsing.value) const LinearProgressIndicator(),
            Expanded(
                child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              controller: controller.tabController,
              children: [
                SearchAllView(controller: controller),
                ...controller.sites.map((site) => SearchListView(site.id))
              ],
            )),
          ])),
    );
  }
}
