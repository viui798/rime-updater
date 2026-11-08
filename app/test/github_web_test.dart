import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/core/github_client.dart';

void main() {
  test('解析网页端 expanded_assets 的资产链接', () {
    const html = '''
<div>
  <a href="/viui798/viui-tiger-sentense/releases/download/v0.3.27/cheese-tiger-v0.3.27-nomodel.zip">
    <span class="text-bold">cheese-tiger-v0.3.27-nomodel.zip</span>
  </a>
  <a href="/viui798/viui-tiger-sentense/releases/download/v0.3.27/cheese-tiger-v0.3.27-update.zip">
    <span class="text-bold">cheese-tiger-v0.3.27-update.zip</span>
  </a>
  <a href="/viui798/viui-tiger-sentense/releases/download/v0.3.27/cheese-tiger-v0.3.27-update.zip">重复</a>
</div>
''';

    final assets = parseExpandedAssets(html);
    expect(assets.map((asset) => asset.name).toList(), [
      'cheese-tiger-v0.3.27-nomodel.zip',
      'cheese-tiger-v0.3.27-update.zip',
    ]);
    expect(
      assets.first.url,
      'https://github.com/viui798/viui-tiger-sentense/releases/download/'
      'v0.3.27/cheese-tiger-v0.3.27-nomodel.zip',
    );
  });

  test('没有资产时返回空列表', () {
    expect(parseExpandedAssets('<div>Nothing here</div>'), isEmpty);
  });
}
