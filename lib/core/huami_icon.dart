/// Huami notification icon ids, as Gadgetbridge defines them.
///
/// Source: `gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/
/// service/devices/huami/HuamiIcon.java:26-62` (id table) and `:64-128`
/// (`mapToIconId`, the NotificationType → icon mapping).
///
/// The id is a single byte in the notification payload (offset 6). The band uses
/// it to pick the glyph shown next to the alert; an unknown id falls back to the
/// generic app icon on the firmware side, but sending a *wrong* id shows a
/// misleading logo, so unmapped apps deliberately use [genericApp] rather than
/// guessing.
class HuamiIcon {
  const HuamiIcon._();

  static const int wechat = 0;
  static const int penguinQq = 1;
  static const int miChat = 2;
  static const int facebook = 3;
  static const int twitter = 4;
  static const int miApp = 5;
  static const int snapchat = 6;
  static const int whatsapp = 7;
  static const int redWhiteFire = 8;
  static const int chinese9 = 9;
  static const int alarmClock = 10;

  /// Generic application icon — Gadgetbridge's fallback for UNKNOWN and for
  /// every notification type it has no specific glyph for.
  static const int genericApp = 11;

  static const int instagram = 12;
  static const int chatBlue = 13;
  static const int cow = 14;
  static const int chinese15 = 15;
  static const int chinese16 = 16;
  static const int star = 17;
  static const int app18 = 18;
  static const int chinese19 = 19;
  static const int chinese20 = 20;
  static const int calendar = 21;
  static const int facebookMessenger = 22;
  static const int viber = 23;
  static const int line = 24;
  static const int telegram = 25;
  static const int kakaotalk = 26;
  static const int skype = 27;
  static const int vkontakte = 28;
  static const int pokemonGo = 29;
  static const int hangouts = 30;
  static const int mi31 = 31;
  static const int chinese32 = 32;
  static const int chinese33 = 33;
  static const int email = 34;
  static const int weather = 35;
  static const int hrWarning = 36;

  /// Android package name → Huami icon id.
  ///
  /// Mirrors Gadgetbridge's `mapToIconId` groupings, translated from its
  /// `NotificationType` enum to the package names Android actually reports.
  /// Anything absent maps to [genericApp] — see [forPackage].
  static const Map<String, int> _byPackage = {
    // Messaging
    'com.whatsapp': whatsapp,
    'com.whatsapp.w4b': whatsapp,
    'org.telegram.messenger': telegram,
    'org.thoughtcrime.securesms': facebookMessenger, // GB maps SIGNAL → 22
    'com.facebook.orca': facebookMessenger,
    'com.viber.voip': viber,
    'jp.naver.line.android': line,
    'com.kakao.talk': kakaotalk,
    'com.skype.raider': skype,
    'com.tencent.mm': wechat,
    'com.tencent.mobileqq': penguinQq,
    'com.vkontakte.android': vkontakte,
    'com.snapchat.android': snapchat,
    'com.google.android.talk': hangouts,
    'com.google.android.apps.messaging': wechat, // GENERIC_SMS → 0
    'com.android.mms': wechat,

    // Social
    'com.facebook.katana': facebook,
    'com.twitter.android': twitter,
    'com.instagram.android': instagram,
    'com.google.android.apps.photos': instagram,
    'com.nianticlabs.pokemongo': pokemonGo,

    // Mail
    'com.google.android.gm': email,
    'com.microsoft.office.outlook': email,
    'com.yahoo.mobile.client.android.mail': email,
    'com.android.email': email,
    'ch.protonmail.android': email,

    // Calendar
    'com.google.android.calendar': calendar,
    'com.android.calendar': calendar,

    // Utilities
    'com.google.android.deskclock': alarmClock,
    'com.android.deskclock': alarmClock,
  };

  /// Icon id for an Android package, defaulting to the generic app glyph.
  ///
  /// Deliberately conservative: an unrecognised app shows the generic icon
  /// rather than a plausible-but-wrong logo.
  static int forPackage(String? package) {
    if (package == null || package.isEmpty) return genericApp;
    return _byPackage[package] ?? genericApp;
  }

  /// Icon for a message/SMS-like alert when no package is known.
  static const int message = wechat;
}
