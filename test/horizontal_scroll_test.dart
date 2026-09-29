import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_admin/app.dart';

/// 首頁橫向捲動回歸：**mouse 拖拽也要能滾**（對應「無法滑動到右側的歌單」）。
/// 樹照抄 home_page：垂直 ListView > Column > SizedBox(170) > 水平 ListView，
/// 並套用與 App 相同的 DesktopScrollBehavior（app.dart builder）。
void main() {
  Widget tree() => MaterialApp(
        builder: (context, child) => ScrollConfiguration(
          behavior: DesktopScrollBehavior(),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: ListView(children: [
            for (var s = 0; s < 3; s++)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('section $s'),
                SizedBox(
                  height: 170,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 30,
                    itemBuilder: (ctx, i) => Container(
                      width: 130,
                      margin: const EdgeInsets.only(right: 10),
                      color: Colors.blue,
                      child: Center(child: Text('$s-$i')),
                    ),
                  ),
                ),
              ]),
          ]),
        ),
      );

  final hList = find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.horizontal);

  Future<void> dragIt(
      WidgetTester tester, PointerDeviceKind kind, String tag) async {
    await tester.pumpWidget(tree());
    final sv = tester.state<ScrollableState>(find.descendant(
        of: hList.last, matching: find.byType(Scrollable)));
    await tester.drag(hList.last, const Offset(-300, 0), kind: kind);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('[$tag] pixels=${sv.position.pixels}');
    expect(sv.position.pixels, greaterThan(0),
        reason: '$kind 拖拽後要有位移');
  }

  testWidgets('touch drag 捲動', (t) async => dragIt(t, PointerDeviceKind.touch, 'touch'));
  testWidgets('mouse drag 捲動', (t) async => dragIt(t, PointerDeviceKind.mouse, 'mouse'));
}
