/// 華語歌手中英名對照（雙向）。純資料，無依賴。
///
/// 為什麼需要：Spotify 有兩條路徑給不同的 artist 名——
///   · open.spotify.com/embed（HTML 爬蟲，spotify_scraper.dart）→ 英文
///     `離開的一路上 - Bestards.mp3`
///   · api-partner.spotify.com（GQL web player）→ 中文
///     ID3 `理想混蛋 Bestards`、年份 2018
/// 兩邊混用 → 全庫中英不一。這裡提供權威對照，讓所有路徑統一顯示中文。
///
/// 收錄標準（不憑記憶）：
///   · 現有 spotify_scraper._cn2en 的 30 筆（既有共識）
///   · spotify_cache 實測反挖（同一 artist 出現「中文 English」並列）
///   · 其餘需使用者/官網確認，不臆測
class ArtistNames {
  const ArtistNames._();

  /// 中文 → 英文。
  static const zh2en = <String, String>{
    // ── 既有 _cn2en（30 筆）──
    '郭靜': 'Claire Kuo',
    '蔡依林': 'Jolin Tsai',
    '盧廣仲': 'Crowd Lu',
    '曾沛慈': 'Pets Tseng',
    '王艷薇': 'Evangeline Wong',
    '胡恂舞': 'Sabrina Hu',
    '周興哲': 'Eric Chou',
    '孫盛希': 'Shi Shi',
    '文慧如': 'Boon Hui Lu',
    '陳忻玥': 'Vicky Chen',
    '邱鋒澤': 'Feng Ze',
    '艾薇': 'Ivy',
    '幻藍小熊': 'GENBLUE',
    '利比': 'LBI',
    '連穎': 'Erin',
    '李芷婷': 'Eleanor',
    '白安': 'Ann Bai',
    '王詩安': 'Diana Wang',
    '陳威全': 'Ethan',
    '持修': 'Chih Siou',
    '羅志祥': 'Show Luo',
    '陳零九': 'Nine Chen',
    '九澤CP': 'Nine Ze CP',
    '告五人': 'Accusefive',
    '理想混蛋': 'Bestards',
    '魏如萱': 'Waa Wei',
    '魏如昀': 'Queen Wei',

    // ── cache 實測反挖（高頻：>=5 首且中英並列出現過）──
    '高爾宣': 'OSN',
    '冰球樂團': 'icyball',
    '芒果醬': 'MangoJump',
    '脆樂團': 'Crispy',
    '李浩瑋': 'HowardLee',
    '大穎': 'DIOR',
    '曾愷妤': 'BIDO',
    '林芃逸': 'PPlin',
    '王泰翔': 'wtx',
    '魔幻力量': 'MP',
    '王謙': 'Goatak',
    '齊翔': 'XIANG',
    '幽靈水晶': 'CRYXTAL',
    '黃瑋昕': 'Haezee',
    '曾柏鈞': 'JIMBo',
    '張鈞': 'lak',
    '公館青少年': 'GGteens',
    '呂植宇': 'LCY',
    '呂建忠': 'TANK',
    '陳佩賢': 'Jesslyn',
    '胡凱兒': 'WhoCares',
    '李哲言': 'JimLee',
    '周祖安': 'ZuAn',
    '王翊恩': 'en',
    '韋德': 'WADE',
    '盧子杰': 'JamesLu',
    '詹雯婷': 'Faye',
    '瘦子': 'ESO',
    '仙杜貝拉': 'Bella',
    '忒修斯': 'Theseus',
    '頑童': 'Mj',
    '呂爵安': 'Edan',
    '鄧福如': 'AF',
    '楊和蘇': 'KeyNG',
    '宏兒': 'KuanHong',
    '蔡詩芸': 'DizzyDizzo',
    '珂拉琪': 'Collage',
    '楊子平': 'CAsPER',
    '品妡': 'babyMINT',
    '陳泳希': 'JUD',
    '紫月光': 'PurpleCrush',
    '裴頡': 'JASMINE',
    '灰灰': 'GrayGray',
    '沈小婷': 'XIAOTING',
    '洪暐': 'Wei',
    '陸杰': 'awr',
    '蔡承祐': 'CY',
    '李想': 'Evelyn',
    '鬍子男': 'Officialdism',
    '政學': 'zedx',
    '禾羽': 'Kimi',
    '冬天': 'Grace',
    '王謙（Lai）': 'Lai',

    // ── 華語歌手的公開中文名（Spotify 註冊名本來就是英文，華語觀眾認中文）──
    // cache 無中英並列佐證（cache 本身全是英文），這些依藝人既定中文名。
    '伍佰': 'Wu Bai',
    '方大同': 'Khalil Fong',
    '楊丞琳': 'Rainie Yang',
    '田馥甄': 'Hebe Tien',
    '小蕭': 'Jam Hsiao',
    '蔡健雅': 'Tanya Chua',
    '張惠妹': 'A-Mei Chang',
    '孫燕姿': 'Stefanie Sun',
    '郭書瑤': 'Kuo Shu-Yao',
    '張震嶽': 'Zhang Zhen Yue',
    '王若琳': 'Silence Wang',
    '郭品韶': 'Amber Kuo',
    '家家': 'Jia Jia',
    '蔡依林（Jolin）': 'Jolin',
    '林俊傑': 'JJ Lin',
    '任賢齊': 'Richie Jen',
    '梁靜茹': 'Fish Leong',
    '陳奕迅': 'Eason Chan',
    '李宗盛': 'Jonathan Lee',
    '周華健': 'Wakin Chau',
    '陳綺貞': 'Cheer Chen',
    '五月天': 'Mayday',
    '蘇打綠': 'sodagreen',
    '宇宙人': 'Cosmos People',
    '閃亮三姊妹': 'S.H.E',
    '江美琪': 'Peggy Hsu',
  };

  static final Map<String, String> _norm2zh = _build();

  static Map<String, String> _build() {
    final m = <String, String>{};
    zh2en.forEach((zh, en) {
      final zhClean = zh.contains('（') ? zh.split('（').first : zh;
      if (zhClean.isEmpty) return;
      // 英文正規化 → 中文（顯示用）；中文正規化 → 中文（統一全形/別名）
      m[_norm(en)] = zhClean;
      m[_norm(zhClean)] = zhClean;
    });
    return m;
  }

  /// lookup key：小寫、去空白與常見標點。
  static final _strip = RegExp(
      "[\\s\\-_·、,，.。!！?？:：;；\"'（）()\\[\\]【】/&.]");

  static String _norm(String s) => s.toLowerCase().replaceAll(_strip, '');

  /// 是否是「本表已知的中文歌手」（用來判斷要不要轉換）。
  static bool isKnownChineseArtist(String artist) {
    final t = artist.trim();
    if (t.isEmpty) return false;
    // 已含中文 → 是中文名，不需轉
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(t)) return true;
    return _norm2zh.containsKey(_norm(t));
  }

  /// 把單一 artist 名轉成中文顯示名；查不到原樣返回。
  static String toDisplay(String artist) {
    final t = artist.trim();
    if (t.isEmpty) return t;
    final hit = _norm2zh[_norm(t)];
    if (hit != null) return hit;
    return t;
  }

  /// 多藝人（逗號分隔）逐段轉中文，**完整保留原始分隔符與空白**。
  /// 注意不能直接呼叫 toDisplay(seg)：它會 trim，吃掉 ", " 的前導空白。
  static String toDisplayList(String artists) {
    if (artists.trim().isEmpty) return artists;
    final buf = StringBuffer();
    var start = 0;
    for (var i = 0; i < artists.length; i++) {
      final c = artists[i];
      if (c == ',' || c == '，') {
        _writeSegment(buf, artists.substring(start, i));
        buf.write(c);
        start = i + 1;
      }
    }
    _writeSegment(buf, artists.substring(start));
    return buf.toString();
  }

  /// 轉一段並原樣保留其前後空白。
  static void _writeSegment(StringBuffer buf, String seg) {
    final lead = seg.substring(0, seg.length - seg.trimLeft().length);
    final trail = seg.substring(seg.trimRight().length);
    final core = seg.trim();
    buf
      ..write(lead)
      ..write(core.isEmpty ? '' : toDisplay(core))
      ..write(trail);
  }
}