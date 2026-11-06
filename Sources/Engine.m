#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "Solver.h"
#import "Engine.h"
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

// Shown in the log and written to Documents/LCAC-2048_over.log. Kept in the
// format string (not passed as an argument) so that os_log does not mask it.
#define TWEAK_VERSION "v3.9"
#define TWEAK_VERSION_OBJC @"v3.9"

// Opaque IL2CPP handles. Resolved with dlsym so the tweak stays independent of
// any UnityFramework headers.
typedef void C;
typedef void M;
typedef void F;

static void *(*domain_get)(void);
static const void **(*assemblies)(const void *, size_t *);
static const void *(*image)(const void *);
static C *(*klass)(const void *, const char *, const char *);
static C *(*object_class)(void *);
static const void *(*class_type)(C *);
static void *(*type_object)(const void *);
static const M *(*class_methods)(C *, void **);
static const char *(*method_name)(const M *);
static uint32_t (*param_count)(const M *);
static bool (*method_generic)(const M *);
static const M *(*method)(C *, const char *, int);
static F *(*field)(C *, const char *);
static void (*field_value)(void *, F *, void *);
static void *(*invoke)(const M *, void *, void **, void **);
static void *(*unbox)(void *);
static const void *(*corlib)(void);
// Optional: only used by the experimental "spawn only 4s" probe. A missing
// symbol must not stop the tweak, so these are loaded separately.
static const void *(*class_fields)(C *, void **);
static const char *(*field_name)(const F *);
static const void *(*field_type)(const F *);
static const char *(*type_get_name)(const void *);
static void (*field_set)(void *, F *, void *);
static uint32_t (*field_flags)(const F *);
static C *(*class_element)(C *);
static C *(*class_parent)(C *);
static const char *(*class_name)(C *);
static const void *(*method_ret)(const M *);
static uint16_t *(*string_chars)(void *);
static uint32_t (*array_len)(void *);

static const void *(*method_param)(const M *, uint32_t);

static C *gmClass, *regularClass, *gridClass, *viewClass;
static void *gmType;
static F *currentField, *viewGridField;
static const M *findObj, *active, *getGrid, *getSize, *getCell, *swipe, *viewInstance, *isMoving;
static BOOL ready = NO, failedInvocation = NO;
static NSString *initStatus = @"I_START";

// Defined below: writes one line to Documents/LCAC-2048.log and nowhere else.
static void logAuto(NSString *format, ...);

#define LOAD(p, n)                                       \
    do {                                                 \
        *(void **)(&(p)) = dlsym(RTLD_DEFAULT, n);       \
        if (!(p)) {                                      \
            initStatus = @"I_API";                       \
            logAuto(@"[2048-auto] API missing: %s", n);    \
            return NO;                                   \
        }                                                \
    } while (0)

static C *findClass(const char *ns, const char *name) {
    size_t n = 0;
    const void **a = assemblies(domain_get(), &n);
    for (size_t i = 0; a && i < n; i++) {
        const void *im = image(a[i]);
        C *c = im ? klass(im, ns, name) : NULL;
        if (c) return c;
    }
    return NULL;
}

// Every managed call goes through here so that a missing method or a managed
// exception is reported once instead of crashing.
static void *call(const M *m, void *obj, void **args) {
    if (!m) {
        failedInvocation = YES;
        return NULL;
    }
    void *exc = NULL;
    void *r = invoke(m, obj, args, &exc);
    if (exc) {
        failedInvocation = YES;
        logAuto(@"[2048-auto] managed exception");
    }
    return r;
}

// initEngine runs on every read (frame), so anything logged from it must be
// once-only. It also has to appear even when the setup below fails.
static void logVersionOnce(void) {
    static int done;
    if (done) return;
    done = 1;
    logAuto(@"[2048-auto] tweak " TWEAK_VERSION " starting");
}

// I_UNITY is transient (the IL2CPP domain comes up late), the rest are final:
// retrying them every frame only floods the log.
static BOOL initEngine(void) {
    logVersionOnce();
    if (ready) return YES;
    if (![initStatus isEqualToString:@"I_START"] && ![initStatus isEqualToString:@"I_UNITY"]) return NO;

    LOAD(domain_get, "il2cpp_domain_get");
    LOAD(assemblies, "il2cpp_domain_get_assemblies");
    LOAD(image, "il2cpp_assembly_get_image");

    LOAD(klass, "il2cpp_class_from_name");
    LOAD(object_class, "il2cpp_object_get_class");
    LOAD(class_type, "il2cpp_class_get_type");

    LOAD(type_object, "il2cpp_type_get_object");
    LOAD(method, "il2cpp_class_get_method_from_name");
    LOAD(field, "il2cpp_class_get_field_from_name");

    LOAD(field_value, "il2cpp_field_get_value");
    LOAD(invoke, "il2cpp_runtime_invoke");

    LOAD(class_methods, "il2cpp_class_get_methods");
    LOAD(method_name, "il2cpp_method_get_name");

    LOAD(param_count, "il2cpp_method_get_param_count");
    LOAD(method_generic, "il2cpp_method_is_generic");
    LOAD(unbox, "il2cpp_object_unbox");
    LOAD(corlib, "il2cpp_get_corlib");

    *(void **)(&string_chars) = dlsym(RTLD_DEFAULT, "il2cpp_string_chars");
    *(void **)(&array_len) = dlsym(RTLD_DEFAULT, "il2cpp_array_length");
    *(void **)(&field_name) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_name");
    *(void **)(&field_type) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_type");
    *(void **)(&type_get_name) = dlsym(RTLD_DEFAULT, "il2cpp_type_get_name");
    *(void **)(&field_set) = dlsym(RTLD_DEFAULT, "il2cpp_field_set_value");
    *(void **)(&field_flags) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_flags");
    *(void **)(&class_element) = dlsym(RTLD_DEFAULT, "il2cpp_class_get_element_class");
    *(void **)(&class_parent) = dlsym(RTLD_DEFAULT, "il2cpp_class_get_parent");
    *(void **)(&class_name) = dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    *(void **)(&method_ret) = dlsym(RTLD_DEFAULT, "il2cpp_method_get_return_type");
    *(void **)(&class_fields) = dlsym(RTLD_DEFAULT, "il2cpp_class_get_fields");
    *(void **)(&field_name) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_name");
    *(void **)(&field_type) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_type");
    *(void **)(&method_param) = dlsym(RTLD_DEFAULT, "il2cpp_method_get_param");

    if (!corlib() || !domain_get()) {
        initStatus = @"I_UNITY";
        return NO;
    }

    gmClass = findClass("Game2048", "GameManager");
    regularClass = findClass("Game2048.GameModes", "RegularGame");
    gridClass = findClass("", "Grid");
    viewClass = findClass("", "GridViewManager");
    C *mode = findClass("Game2048.GameModes", "GameMode");
    C *obj = findClass("UnityEngine", "Object");

    if (!gmClass || !regularClass || !gridClass || !viewClass || !mode || !obj) {
        initStatus = @"I_CLASS";
        logAuto(@"[2048-auto] class manager=%p regular=%p grid=%p view=%p mode=%p obj=%p", gmClass, regularClass,
              gridClass, viewClass, mode, obj);
        return NO;
    }

    gmType = type_object(class_type(gmClass));
    currentField = field(gmClass, "_currentGame");
    viewGridField = field(viewClass, "_grid");

    // There is also FindFirstObjectByType<T>(FindObjectsInactive), with the same
    // name and arity. A plain name/arity lookup may select that open generic.
    // Select the non-generic (System.Type) overload as in LCAC-A.
    findObj = NULL;
    void *it = NULL;
    const M *candidate;
    while ((candidate = class_methods(obj, &it))) {
        const char *n = method_name(candidate);
        if (n && !strcmp(n, "FindFirstObjectByType") && param_count(candidate) == 1 &&
            !method_generic(candidate)) {
            findObj = candidate;
            break;
        }
    }

    active = method(regularClass, "get_GameActive", 0);
    getGrid = method(mode, "get_Grid", 0);
    getSize = method(gridClass, "get_Size", 0);
    getCell = method(gridClass, "GetCellValue", 1);
    swipe = method(gmClass, "HandleSwipe", 1);
    viewInstance = method(viewClass, "get_Instance", 0);
    isMoving = method(viewClass, "IsAnyTileMoving", 0);

    if (!gmType || !currentField || !viewGridField || !findObj || !active || !getGrid || !getSize || !getCell ||
        !swipe || !viewInstance || !isMoving) {
        initStatus = @"I_METHOD";
        logAuto(@"[2048-auto] type=%p fields=%p,%p methods=%p,%p,%p,%p,%p,%p,%p,%p", gmType, currentField,
              viewGridField, findObj, active, getGrid, getSize, getCell, swipe, viewInstance, isMoving);
        return NO;
    }

    // Printed as literal text (not an argument) so that os_log shows it.
    logAuto(@"[2048-auto] tweak " TWEAK_VERSION ": 2->4 rewrite, game over log");
    ready = YES;
    return YES;
}

typedef struct {
    int32_t x, y;
} Vec2;

// --- run log ---------------------------------------------------------------
// Only the tweak's own lines are kept, and only in Documents/LCAC-2048.log:
// nothing is printed to the console. The app's own chatter (ads, analytics
// retries every few seconds) used to fill the file, so NSLog is not used at
// all; every line goes through logAuto below.
static int logFileFd = -2; // -2: not opened yet, -1: could not open
static NSString *logPath;

static NSString *documentsPath(NSString *name) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return nil;
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:name];
}

static void logOpenFile(void) {
    logPath = documentsPath(@"LCAC-2048.log");
    if (!logPath) return;
    NSFileManager *files = [NSFileManager defaultManager];
    NSDictionary *attrs = [files attributesOfItemAtPath:logPath error:NULL];
    // Only our own lines go in, so it stays small; start over past 1 MB.
    if ([[attrs objectForKey:NSFileSize] unsignedLongLongValue] > 1ull * 1024 * 1024)
        [files removeItemAtPath:logPath error:NULL];
    logFileFd = open([logPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
}

// A read runs every frame, so a message logged from one path can repeat
// thousands of times. Identical consecutive lines are folded into one line per
// 100 repeats, and the file as a whole stops at LOG_MAX_LINES as a backstop.
#define LOG_MAX_LINES 20000

static void logAuto(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSString *lastBody;
    static int repeats;
    static int lines;
    if (lastBody && [body isEqualToString:lastBody]) {
        repeats++;
        if (repeats % 100 != 0) return; // 100 回ごとに 1 行だけ残す
        body = [body stringByAppendingFormat:@" (repeated %d times)", repeats + 1];
    } else {
        lastBody = body;
        repeats = 0;
    }
    if (lines >= LOG_MAX_LINES) return;
    if (++lines == LOG_MAX_LINES) body = [body stringByAppendingString:@" (log limit reached)"];
    static NSDateFormatter *stamp;
    if (!stamp) {
        stamp = [[NSDateFormatter alloc] init];
        // The device locale would print 午前/午後 and break every log parser.
        [stamp setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        [stamp setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    }
    NSString *text = [NSString stringWithFormat:@"%@ %@\n", [stamp stringFromDate:[NSDate date]], body];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (logFileFd == -2) logOpenFile();
    if (logFileFd < 0) return;
    (void)!write(logFileFd, [data bytes], [data length]);
}

// --- experimental: force every new tile to be a 4 ---------------------------
// The game keeps the odds of a 4 somewhere. If a float field of GameManager or
// Grid looks like it (its name contains "four"), the tweak raises it to 1.0 and
// tells the solver that only 4s appear. Every spawned tile is then checked: if a
// 2 still shows up, the field is put back and the solver returns to 2/4.
enum { FIELD_NONE = 0, FIELD_GAME_MANAGER = 1, FIELD_GRID = 2 };
static F *fourField;
static int fourOwner;
static float fourOldValue;
static int fourProbeDone, fourSpawns, fourReverted;
static int32_t expected[16];
static BOOL haveExpected;

// If no chance field exists, the other route is to rewrite the cell the game
// just filled: a spawned 2 becomes a 4. Only used when the setter is proven to
// work (write, read back, compare), and switched off if 2s come back.
static const M *setCellMethod;
static int converting;
// The board on screen is drawn by the view from the tile objects, so a grid
// write alone only changes the game's logic, not the picture. If the view has
// a no-argument redraw entry point, call it after rewriting.
static const M *viewRefresh;
static int refreshLogged;

static const M *findSetter(void) {
    static const char *names[] = {"SetCellValue", "SetCell", "SetValue", "SetTileValue", "SetTile", "SetNumber"};
    for (int i = 0; i < 6; i++) {
        const M *m = method(gridClass, names[i], 2);
        if (m) return m;
    }
    return NULL;
}

// Writes v into (x, y) and reads it back. Returns NO unless the grid really
// holds the new value, so a wrong guess can never desync the board.
static BOOL writeCell(void *grid, int x, int y, int32_t v) {
    if (!setCellMethod || !grid) return NO;
    Vec2 c = {x, y};
    int32_t val = v;
    void *par[] = {&c, &val};
    BOOL saved = failedInvocation;
    failedInvocation = NO;
    call(setCellMethod, grid, par);
    BOOL ok = NO;
    if (!failedInvocation) {
        void *back[] = {&c};
        void *box = call(getCell, grid, back);
        ok = box && !failedInvocation && *(int32_t *)unbox(box) == v;
    }
    failedInvocation = saved;
    return ok;
}


// --- diagnostics -----------------------------------------------------------
// One line per read while diagLeft lasts: the board we are about to play from.
// Numbers come through os_log unmasked (<private> only hides strings).
// Debug output (board history, class/method dumps, probe and redraw trace) is
// kept in the code but switched off. Set this to 1 to see it again; the twos in
// `board 1` and the mismatch lines are the first thing to look at.
static int diagEnabled = 0;
static int diagLeft = 40;

// Method and class names as two 7-bit packed numbers: os_log masks strings
// ("<private>") but never numbers.
// Same idea as encName, but keeps 24 characters. Used when a name has to be
// identified exactly (the restart entry point is longer than 16 characters).
static void encName3(const char *s, unsigned long long out[3]) {
    out[0] = out[1] = out[2] = 0;
    for (int i = 0; s && s[i] && i < 24; i++)
        out[i / 8] |= ((unsigned long long)(unsigned char)s[i]) << (7 * (i % 8));
}

// A managed string (UTF-16) packed the same way; used for GameObject names.
// Unity object names are ASCII, so the low 7 bits are enough.
static void encManagedName(void *str, unsigned long long out[3]) {
    out[0] = out[1] = out[2] = 0;
    if (!str || !string_chars) return;
    const uint16_t *ch = string_chars(str);
    if (!ch) return;
    // UTF-8 bytes, so Japanese names survive the 7-bit packing as well.
    int n = 0;
    for (int i = 0; ch[i] && n < 24; i++) {
        unsigned int c = ch[i];
        unsigned char b[3];
        int k;
        if (c < 0x80) {
            b[0] = (unsigned char)c;
            k = 1;
        } else if (c < 0x800) {
            b[0] = (unsigned char)(0xc0 | (c >> 6));
            b[1] = (unsigned char)(0x80 | (c & 0x3f));
            k = 2;
        } else {
            b[0] = (unsigned char)(0xe0 | (c >> 12));
            b[1] = (unsigned char)(0x80 | ((c >> 6) & 0x3f));
            b[2] = (unsigned char)(0x80 | (c & 0x3f));
            k = 3;
        }
        for (int j = 0; j < k && n < 24; j++, n++)
            out[n / 8] |= ((unsigned long long)b[j]) << (7 * (n % 8));
    }
}

// Plain ASCII copy of a managed string (keywords only; names are ASCII).
// Long enough for names like "ClassicRegularGameLoseScreen": a keyword can sit
// far past the 24 characters that are logged.
static void managedName(void *str, char out[64]) {
    out[0] = 0;
    if (!str || !string_chars) return;
    const uint16_t *ch = string_chars(str);
    if (!ch) return;
    int i = 0;
    for (; i < 63 && ch[i]; i++) out[i] = (char)(ch[i] & 0x7f);
    out[i] = 0;
}

// A managed array: header (object 16, bounds 8, length 8) then the elements.
// il2cpp_array_length is not exported everywhere, so the layout is the fallback.
static int managedCount(void *arr) {
    if (!arr) return 0;
    if (array_len) return (int)array_len(arr);
    uintptr_t n = *(uintptr_t *)((char *)arr + 24);
    return n > 5000 ? 0 : (int)n;
}

static void *managedItem(void *arr, int i) {
    if (!arr || i < 0) return NULL;
    return *(void **)((char *)arr + 32 + (size_t)i * sizeof(void *));
}

static void encName(const char *s, unsigned long long out[2]) {
    out[0] = out[1] = 0;
    for (int i = 0; s && s[i] && i < 16; i++)
        out[i / 8] |= ((unsigned long long)(unsigned char)s[i]) << (7 * (i % 8));
}

static void dumpNames(C *c, int tag) {
    if (!c || !class_methods || !method_name) return;
    void *it = NULL;
    const M *m;
    while ((m = class_methods(c, &it))) {
        unsigned long long e[2];
        encName(method_name(m), e);
        if (diagEnabled) logAuto(@"[2048-auto] name %d %d %llx %llx", tag, (int)param_count(m), e[0], e[1]);
    }
}

static BOOL containsWord(const char *n, const char *key) {
    if (!n || !key) return NO;
    size_t len = strlen(key);
    for (const char *p = n; *p; p++) {
        size_t i = 0;
        while (i < len && p[i]) {
            char c = (p[i] >= 'A' && p[i] <= 'Z') ? (char)(p[i] - 'A' + 'a') : p[i];
            if (c != key[i]) break;
            i++;
        }
        if (i == len) return YES;
    }
    return NO;
}

static void logBoard(int tag, const int32_t *b) {
    if (!diagEnabled) return;
    logAuto(@"[2048-auto] board %d: %d %d %d %d | %d %d %d %d | %d %d %d %d | %d %d %d %d", tag, b[0], b[1],
          b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
}

static BOOL containsFour(const char *s) {
    if (!s) return NO;
    for (const char *p = s; *p; p++) {
        char c = (*p >= 'F' && *p <= 'Z') ? (char)(*p - 'A' + 'a') : *p;
        if (c != 'f') continue;
        char w[5] = {c, p[1], p[2], p[3], 0};
        for (int i = 1; i < 4; i++)
            if (w[i] >= 'F' && w[i] <= 'Z') w[i] = (char)(w[i] - 'A' + 'a');
        if (!strcmp(w, "four")) return YES;
    }
    return NO;
}

static void applyFour(int owner, void *obj) {
    if (fourOwner != owner || !fourField || !field_set) return;
    float one = 1.0f;
    field_set(obj, fourField, &one);
}

static void probeFields(C *c, void *obj, int owner, const char *label) {
    if (!c || !obj || !class_fields || !field_name || !field_type || !type_get_name) return;
    void *it = NULL;
    const F *f;
    while ((f = class_fields(c, &it))) {
        const char *n = field_name(f);
        const void *t = field_type(f);
        const char *tn = t ? type_get_name(t) : NULL;
        BOOL isStatic = field_flags ? (field_flags(f) & 0x10) != 0 : NO;
        void *target = isStatic ? NULL : obj;
        if (!tn || strcmp(tn, "System.Single")) continue;
        float v = 0;
        field_value(target, (F *)f, &v);
        if (diagEnabled && containsFour(n)) logAuto(@"[2048-auto] %s.%s = %g (spawn candidate)", label, n ? n : "?", v);
        if (!fourOwner && containsFour(n) && v >= 0.0f && v <= 1.0f) {
            fourField = (F *)f;
            fourOwner = owner;
            fourOldValue = v;
            if (v < 1.0f && field_set) {
                float one = 1.0f;
                field_set(target, (F *)f, &one);
            }
            logAuto(@"[2048-auto] spawn forced to 4 via %s.%s (%g -> 1)", label, n ? n : "?", v);
        }
    }
}

// --- game over: keep the final board ---------------------------------------
// The app has no log of its own, so the last board is appended to
// Documents/LCAC-2048_over.log when no move is left. One block per game; the
// flag resets as soon as the board can move again (new game or undo).
static int gameOverLogged;
static const M *scoreGetter;
static F *scoreField;
static int scoreOnGame;

// Same test the solver uses to decide whether a move exists, so there is only
// one implementation of the rules.
static BOOL anyMovePossible(const int32_t *b) {
    int32_t after[16];
    for (int d = 0; d < 4; d++)
        if (solver_move(b, d, after)) return YES;
    return NO;
}

// The score lives somewhere on GameManager or on the running game object. Both
// are probed once; if neither has it the log shows -1 instead of failing.
static void findScore(void *game) {
    if (scoreGetter || scoreField) return;
    static const char *getters[] = {"get_Score", "GetScore", "get_TotalScore", "get_ScoreValue"};
    static const char *fields[] = {"_score", "score", "Score", "_totalScore", "totalScore"};
    C *classes[2];
    classes[0] = gmClass;
    classes[1] = game ? object_class(game) : NULL;
    for (int c = 0; c < 2 && !scoreGetter && !scoreField; c++) {
        C *k = classes[c];
        if (!k) continue;
        for (int i = 0; i < 4 && !scoreGetter; i++) {
            const M *m = method(k, getters[i], 0);
            if (m) {
                scoreGetter = m;
                scoreOnGame = c;
            }
        }
        for (int i = 0; i < 5 && !scoreField; i++) scoreField = field(k, fields[i]);
        if (!scoreGetter) {
            void *it = NULL;
            const M *m;
            while ((m = class_methods(k, &it))) {
                const char *n = method_name(m);
                if (!n || param_count(m) != 0) continue;
                if (!containsWord(n, "score") || containsWord(n, "high")) continue;
                scoreGetter = m;
                scoreOnGame = c;
                break;
            }
        }
    }
}

static long long readScore(void *mgr, void *game) {
    findScore(game);
    void *target = scoreOnGame ? game : mgr;
    if (scoreGetter && target) {
        void *box = call(scoreGetter, target, NULL);
        if (!failedInvocation && box) return *(int32_t *)unbox(box);
    }
    if (scoreField && field_value && target) {
        int32_t v = 0;
        field_value(target, scoreField, &v);
        if (!failedInvocation) return v;
    }
    return -1;
}

// The "play again" button in the game calls a single method. Looked up by name
// because the app hides managed names from logs, not from the runtime.
static const M *restartList[8];
static int restartListOnGame[8];
static int restartCount;
static int restartIndex;
// The candidate that actually started a new game. Once known it is used for
// every later game over: trying the others again only breaks the next restart.
static int restartGood = -1;
static int restartSlot;
static int restartLooked;
// Set when a restart was asked for; the next readable board reports whether it
// actually took effect.
static int restartPending;
// When the game first came back as PAUSE. A pause is normal (game over screen,
// achievement screen, ad) and must never be turned into a restart on its own:
// doing that throws away a game that is still playable.
static double pauseSince;
static int pauseLogged;

// The game over screen is not part of the model, so restarting the model leaves
// it on screen. The scene tree says which object it is:
//
//   MenuManager > ClassicRegularGameHud > Body > LayoutParent > Logo,
//                                                              ScoreContainer,
//                                                              BestScoreContainer, ...
//
// "Body" is the overlay that carries the logo, the score and the buttons. It is
// off while a game is running, so it has to be switched off again after the
// model has been restarted for the player.
static int overlayHidesLeft;
static C *objClassRef;

// Object.FindObjectsOfType(Type): every object of a class that is in the scene.
static void *findAllOf(C *k) {
    if (!k || !objClassRef || !class_type || !type_object) return NULL;
    const M *findAll = NULL;
    void *it = NULL;
    const M *candidate;
    while ((candidate = class_methods(objClassRef, &it))) {
        const char *n = method_name(candidate);
        if (!n || strcmp(n, "FindObjectsOfType") || param_count(candidate) != 1 || method_generic(candidate))
            continue;
        findAll = candidate;
        break;
    }
    if (!findAll) return NULL;
    void *typeObj = type_object(class_type(k));
    if (!typeObj) return NULL;
    void *par[] = {typeObj};
    void *arr = call(findAll, NULL, par);
    return failedInvocation ? NULL : arr;
}

// Whether the game loop is running at all. A frozen counter means the screen is
// not being redrawn, so hiding an object would look like it did nothing.
static void logFrame(const char *tag) {
    C *t = findClass("UnityEngine", "Time");
    const M *fc = t ? method(t, "get_frameCount", 0) : NULL;
    if (!fc) return;
    void *box = call(fc, NULL, NULL);
    if (failedInvocation || !box) return;
    logAuto(@"[2048-auto] frame %d %s", *(int32_t *)unbox(box), tag);
}

// The game over screen has a name of its own after all:
//
//   MenuManager > ClassicRegularGameLoseScreen   (regular games)
//                 ClassicChallengeLoseScreen     (daily challenge)
//
// Only those are switched off. The HUD (score, menu, leaderboard) lives in a
// different object and must stay visible.
// The HUD switches itself off when the game ends, and the game only switches it
// back on when it starts a game by itself. It is a sibling of the lose screen:
//
//   MenuManager > ClassicRegularGameHud > Body     (score, menu, leaderboard)
//               > ClassicRegularGameLoseScreen
//
// Walking the parent's children works even while they are switched off.
static void showHudBeside(void *loseScreen, const char *loseName) {
    C *goClass = findClass("UnityEngine", "GameObject");
    C *compClass = findClass("UnityEngine", "Component");
    C *trClass = findClass("UnityEngine", "Transform");
    if (!goClass || !compClass || !trClass || !string_chars) return;
    const M *goTransform = method(goClass, "get_transform", 0);
    const M *setActive = method(goClass, "SetActive", 1);
    const M *getParent = method(trClass, "get_parent", 0);
    const M *getChildCount = method(trClass, "get_childCount", 0);
    const M *getChild = method(trClass, "GetChild", 1);
    const M *getGameObject = method(compClass, "get_gameObject", 0);
    const M *nameOf = method(objClassRef, "get_name", 0);
    if (!goTransform || !setActive || !getParent || !getChildCount || !getChild || !getGameObject || !nameOf)
        return;
    void *tr = call(goTransform, loseScreen, NULL);
    void *up = tr ? call(getParent, tr, NULL) : NULL;
    if (!up || failedInvocation) return;
    void *cnt = call(getChildCount, up, NULL);
    if (failedInvocation || !cnt) return;
    int n = *(int32_t *)unbox(cnt);
    for (int i = 0; i < n; i++) {
        int32_t idx = i;
        void *par[] = {&idx};
        void *child = call(getChild, up, par);
        if (failedInvocation || !child) continue;
        void *go = call(getGameObject, child, NULL);
        void *nm = go ? call(nameOf, go, NULL) : NULL;
        if (!nm || failedInvocation) continue;
        char plain[64];
        managedName(nm, plain);
        // MenuManager owns one HUD per mode. Showing both draws the score and
        // the menu twice, so only the one that belongs to this game is used.
        BOOL challenge = (BOOL)containsWord(loseName, "challenge");
        if (!containsWord(plain, "hud")) continue;
        if (challenge ? !containsWord(plain, "challenge") : !containsWord(plain, "regular")) continue;
        uint8_t on = 1;
        void *p[] = {&on};
        call(setActive, go, p);
        // ...and the body inside it, which is the part that disappears.
        void *cc = call(getChildCount, child, NULL);
        if (failedInvocation || !cc) continue;
        int m = *(int32_t *)unbox(cc);
        for (int j = 0; j < m; j++) {
            int32_t k = j;
            void *par2[] = {&k};
            void *sub = call(getChild, child, par2);
            if (failedInvocation || !sub) continue;
            void *sgo = call(getGameObject, sub, NULL);
            void *snm = sgo ? call(nameOf, sgo, NULL) : NULL;
            if (!snm || failedInvocation) continue;
            char sp[64];
            managedName(snm, sp);
            if (strcmp(sp, "Body")) continue;
            void *p2[] = {&on};
            call(setActive, sgo, p2);
        }
        logAuto(@"[2048-auto] hud shown");
    }
}

static void hideLoseScreen(BOOL verbose) {
    C *goClass = findClass("UnityEngine", "GameObject");
    C *objClass = objClassRef = findClass("UnityEngine", "Object");
    if (!goClass || !objClass) return;
    const M *nameOf = method(objClass, "get_name", 0);
    const M *setActive = method(goClass, "SetActive", 1);
    if (!nameOf || !setActive) return;
    void *arr = findAllOf(goClass);
    if (!arr) return;
    int total = managedCount(arr);
    int hidden = 0;
    for (int i = 0; i < total && i < 400; i++) {
        void *go = managedItem(arr, i);
        if (!go) continue;
        void *nm = call(nameOf, go, NULL);
        if (failedInvocation || !nm) continue;
        char plain[64];
        managedName(nm, plain);
        if (!containsWord(plain, "losescreen") && !containsWord(plain, "gameover")) continue;
        if (verbose) {
            unsigned long long c[3] = {0, 0, 0};
            encManagedName(nm, c);
            logAuto(@"[2048-auto] lose screen %llx %llx %llx", c[0], c[1], c[2]);
        }
        uint8_t off = 0;
        void *p[] = {&off};
        call(setActive, go, p);
        hidden++;
        showHudBeside(go, plain);
    }
    if (hidden || verbose) logAuto(@"[2048-auto] lose screen hidden (%d of %d objects)", hidden, total);
}

// A "play again" handler is quite often a coroutine: invoking it only builds an
// IEnumerator, and nothing happens until it is handed to StartCoroutine.
static const M *startCoroutine;
static int startCoroutineLooked;

static const M *findStartCoroutine(void) {
    if (startCoroutineLooked) return startCoroutine;
    startCoroutineLooked = 1;
    C *k = gmClass;
    for (int depth = 0; k && method_param && class_parent && class_name && depth < 12; depth++) {
        const char *n = class_name(k);
        if (n && !strcmp(n, "MonoBehaviour")) {
            void *it = NULL;
            const M *m;
            while ((m = class_methods(k, &it))) {
                const char *mn = method_name(m);
                if (!mn || strcmp(mn, "StartCoroutine") || param_count(m) != 1) continue;
                const void *pt = method_param(m, 0);
                const char *tn = pt ? type_get_name(pt) : NULL;
                if (tn && strstr(tn, "IEnumerator")) {
                    startCoroutine = m;
                    break;
                }
            }
        }
        k = class_parent(k);
    }
    return startCoroutine;
}

// The exact name is not known: the app hides method names from logs, and the
// truncated dump only shows the first 16 characters. Match by keyword instead,
// preferring methods that take no arguments.
static void findRestart(void *game) {
    if (restartLooked) return;
    restartLooked = 1;
    static const char *keys[] = {"restart", "playagain", "newgame", "newround", "startover"};
    C *classes[2];
    classes[0] = gmClass;
    classes[1] = game ? object_class(game) : NULL;
    for (int c = 0; c < 2 && restartCount < 8; c++) {
        C *k = classes[c];
        if (!k) continue;
        void *it = NULL;
        const M *m;
        while ((m = class_methods(k, &it))) {
            const char *n = method_name(m);
            if (!n || param_count(m) != 0) continue;
            for (int i = 0; i < 5; i++) {
                if (!containsWord(n, keys[i])) continue;
                unsigned long long e[3], r[3] = {0, 0, 0};
                encName3(n, e);
                const void *rt = method_ret ? method_ret(m) : NULL;
                if (rt && type_get_name) encName3(type_get_name(rt), r);
                logAuto(@"[2048-auto] restart candidate %d %llx %llx %llx ret %llx %llx %llx", (int)param_count(m),
                      e[0], e[1], e[2], r[0], r[1], r[2]);
                if (restartCount < 8) {
                    restartList[restartCount] = m;
                    restartListOnGame[restartCount] = c;
                    restartCount++;
                }
                break;
            }
        }
    }
}

// --- progress: how many moves were played, and when a big tile appeared -----
// One move is one swipe the tweak actually sent. The counter resets when a new
// game starts (a different Grid, or a board that is back to two tiles).
static void *trackedGrid;
static long long moveCount;
static int bestTile;
static long long progressAt;
// 出現位置の分布。アプリの抽選が一様かどうかを実機で測るためのもの。
// spawnCount = そのマスに出た回数、spawnChance = そのマスが空いていた回数。
static int spawnCount[16];
static int spawnChance[16];
static int spawnMiss;

static void logMilestone(const int32_t *b, long long score, long long moves, int tile) {
    logAuto(@"[2048-auto] milestone tile=%d score=%lld moves=%lld board %d,%d,%d,%d | %d,%d,%d,%d | %d,%d,%d,%d | "
           "%d,%d,%d,%d",
          tile, score, moves, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12],
          b[13], b[14], b[15]);
}

// 500 手ごとの経過。8,192 を作ったあとにどこで崩れるかを見るための記録で、
// milestone と同じ並び (1 行目が画面の一番下) で盤面を残す。
static void logProgress(const int32_t *b, long long score, long long moves) {
    logAuto(@"[2048-auto] progress moves=%lld score=%lld board %d,%d,%d,%d | %d,%d,%d,%d | "
           "%d,%d,%d,%d | %d,%d,%d,%d",
          moves, score, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12],
          b[13], b[14], b[15]);
}

// Called on every read, so it must stay cheap: the board is already in memory
// and the score is only read when a new tile shows up.
static void trackProgress(void *grid, const int32_t *b, void *mgr, void *game) {
    int tiles = 0, max = 0;
    for (int i = 0; i < 16; i++) {
        if (b[i]) tiles++;
        if (b[i] > max) max = b[i];
    }
    if (grid != trackedGrid || (tiles <= 2 && moveCount > 0)) {
        trackedGrid = grid;
        moveCount = 0;
        progressAt = 0;
        for (int i = 0; i < 16; i++) spawnCount[i] = spawnChance[i] = 0;
        spawnMiss = 0;
        // 装着した時点で既に載っているタイルは「作った」わけではないので記録しない。
        bestTile = max;
        return;
    }
    if (moveCount >= progressAt + 500) {
        progressAt = moveCount;
        logProgress(b, readScore(mgr, game), moveCount);
    }
    if (max <= bestTile) return;
    bestTile = max;
    // 2048 以上で、2 の累乗のタイルが増えたときだけ記録する。
    if (max < 2048 || (max & (max - 1)) != 0) return;
    logMilestone(b, readScore(mgr, game), moveCount, max);
}

// Logged once per game so that the spawn distribution can be compared with the
// uniform draw the solver assumes.
static void logSpawnHistogram(void) {
    logAuto(@"[2048-auto] spawns miss=%d count %d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d chance "
           "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
          spawnMiss, spawnCount[0], spawnCount[1], spawnCount[2], spawnCount[3], spawnCount[4], spawnCount[5],
          spawnCount[6], spawnCount[7], spawnCount[8], spawnCount[9], spawnCount[10], spawnCount[11],
          spawnCount[12], spawnCount[13], spawnCount[14], spawnCount[15], spawnChance[0], spawnChance[1],
          spawnChance[2], spawnChance[3], spawnChance[4], spawnChance[5], spawnChance[6], spawnChance[7],
          spawnChance[8], spawnChance[9], spawnChance[10], spawnChance[11], spawnChance[12], spawnChance[13],
          spawnChance[14], spawnChance[15]);
}

static void saveGameOver(const int32_t *b, long long score) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return;
    NSString *path = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"LCAC-2048_over.log"];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss Z"];
    NSString *when = [formatter stringFromDate:[NSDate date]];

    // The game's grid counts y from the bottom of the screen, so the first row
    // written here is the bottom row of the board. tools/board_image.py turns
    // the block back into a picture and flips it to match the screen.
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@ %@ score=%lld moves=%lld\n", when, TWEAK_VERSION_OBJC, score, moveCount];
    for (int y = 0; y < 4; y++)
        [text appendFormat:@"%6d %6d %6d %6d\n", b[4 * y], b[4 * y + 1], b[4 * y + 2], b[4 * y + 3]];
    [text appendString:@"\n"];

    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    [handle seekToEndOfFile];
    [handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

// Called from the normal read path with a board that was just parsed.
static void noteGameOver(const int32_t *board, void *mgr, void *game) {
    if (anyMovePossible(board)) {
        gameOverLogged = 0;
        return;
    }
    if (gameOverLogged) return;
    gameOverLogged = 1;
    saveGameOver(board, readScore(mgr, game));
    logSpawnHistogram();
    logAuto(@"[2048-auto] game over: board saved");
}

// Called when the game has already stopped taking input: the board is still
// readable there, and that is where the final position usually shows up.
static void checkGameOverQuietly(void *mgr, void *game) {
    if (!getGrid || !getCell) return;
    void *grid = call(getGrid, game, NULL);
    if (failedInvocation || !grid) return;
    int32_t b[16];
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            Vec2 v = {x, y};
            void *par[] = {&v};
            void *box = call(getCell, grid, par);
            if (failedInvocation || !box) return;
            b[x + 4 * y] = *(int32_t *)unbox(box);
        }
    }
    // A win screen can appear the instant a big tile is built, so the board has
    // to count for the milestones here as well; otherwise that tile is lost from
    // the log.
    trackProgress(grid, b, mgr, game);
    noteGameOver(b, mgr, game);
    // Long pause with a playable board: keep the position in the log and wait.
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (pauseSince == 0) pauseSince = now;
    if (!pauseLogged && now - pauseSince > 5.0) {
        pauseLogged = 1;
        logAuto(@"[2048-auto] paused 5 s; board %d,%d,%d,%d | %d,%d,%d,%d | %d,%d,%d,%d | %d,%d,%d,%d",
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14],
                b[15]);
    }
}

// What draws the board, and where the cells live. Logged once so the next
// version can refresh the picture after the rewrite (the grid alone does not
// change what is on screen).
static void probeDraw(void *grid) {
    BOOL debug = diagEnabled != 0;
    if (debug) dumpNames(viewClass, 5);
    if (debug) {
        const M *cellsM = method(gridClass, "get_Cells", 0);
        if (cellsM) {
            void *cells = call(cellsM, grid, NULL);
            if (cells && !failedInvocation) {
                C *ac = object_class(cells);
                C *ec = (ac && class_element) ? (C *)class_element(ac) : NULL;
                logAuto(@"[2048-auto] cells class %llx elem %llx", (unsigned long long)(uintptr_t)ac,
                      (unsigned long long)(uintptr_t)ec);
                dumpNames(ec, 4);
            }
        }
    }
    static const char *keys[] = {"refresh", "redraw", "rebuild", "render", "updateboard", "updatedisplay",
                                 "updateall", "sync"};
    void *it = NULL;
    const M *m;
    while ((m = class_methods(viewClass, &it)) && !viewRefresh) {
        if (param_count(m) != 0) continue;
        for (int k = 0; k < 8; k++)
            if (containsWord(method_name(m), keys[k])) {
                viewRefresh = m;
                break;
            }
    }
    if (viewRefresh && diagEnabled) logAuto(@"[2048-auto] view redraw found");
}

static void probeSpawn(void *mgr, void *grid) {
    if (fourProbeDone) return;
    fourProbeDone = YES;
    probeFields(gmClass, mgr, FIELD_GAME_MANAGER, "GameManager");
    probeFields(gridClass, grid, FIELD_GRID, "Grid");
    if (!fourOwner) {
        setCellMethod = findSetter();
        if (diagEnabled) logAuto(@"[2048-auto] probe self %llx grid %llx setter %llx", (unsigned long long)(uintptr_t)&converting,
              (unsigned long long)(uintptr_t)grid, (unsigned long long)(uintptr_t)setCellMethod);
        // Prove the setter by writing a cell's own value back before using it.
        BOOL saved = failedInvocation;
        failedInvocation = NO;
        BOOL ok = NO;
        for (int i = 0; i < 16 && setCellMethod && !ok; i++) {
            int x = i % 4, y = i / 4;
            Vec2 c = {x, y};
            void *par[] = {&c};
            void *box = call(getCell, grid, par);
            if (!box || failedInvocation) break;
            int32_t v = *(int32_t *)unbox(box);
            if (v > 0 && writeCell(grid, x, y, v)) ok = YES;
        }
        failedInvocation = saved;
        if (ok) {
            converting = 1;
            solver_set_spawn_value(4);
            logAuto(@"[2048-auto] grid setter works; spawned 2s are turned into 4s");
            probeDraw(grid);
        } else {
            logAuto(@"[2048-auto] no four-chance field and no grid setter; spawns stay 2/4");
        }
    }
}

static void revertFour(void *mgr, void *grid) {
    if (fourReverted) return;
    fourReverted = 1;
    void *target = fourOwner == FIELD_GRID ? grid : mgr;
    if (target && fourField && field_set) {
        float old = fourOldValue;
        field_set(target, (F *)fourField, &old);
    }
    fourOwner = FIELD_NONE;
    solver_set_spawn_value(0);
    logAuto(@"[2048-auto] a 2 spawned after forcing; reverting to 2/4");
}

// Returns status for UI; all calls occur on Unity's main thread. Unsupported modes do nothing.
NSString *Auto2048Read(Auto2048Snapshot *out) {
    if (!out) return @"ERR";
    if (!initEngine()) return initStatus;

    failedInvocation = NO;
    void *args[] = {gmType};
    void *mgr = call(findObj, NULL, args);
    if (failedInvocation) return @"F_EXC";
    if (!mgr) return @"F_MGR";

    void *game = NULL;
    field_value(mgr, currentField, &game);
    if (!game || object_class(game) != regularClass) return @"MODE";

    void *box = call(active, game, NULL);
    if (failedInvocation || !box || !*(uint8_t *)unbox(box)) {
        // The game stops taking input once it is over, and that is exactly when
        // the last board has to be written out. While the board can still move
        // this is only a screen (achievement, ad, menu), so nothing is
        // restarted: the player decides.
        checkGameOverQuietly(mgr, game);
        return @"PAUSE";
    }
    pauseSince = 0;
    pauseLogged = 0;

    void *grid = call(getGrid, game, NULL);
    if (failedInvocation) return @"G_EXC";
    if (!grid) return @"G_NULL";

    void *view = call(viewInstance, NULL, NULL);
    if (failedInvocation) return @"V_EXC";
    if (!view) return @"V_NULL";

    void *displayedGrid = NULL;
    field_value(view, viewGridField, &displayedGrid);
    if (displayedGrid != grid) return @"V_GRID";

    box = call(isMoving, view, NULL);
    if (failedInvocation || !box) return @"ERR";
    if (*(uint8_t *)unbox(box)) return @"V_MOVE";

    box = call(getSize, grid, NULL);
    if (failedInvocation || !box || *(int32_t *)unbox(box) != 4) return @"SIZE";

    int32_t board[16];
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            Vec2 v = {x, y};
            void *par[] = {&v};
            box = call(getCell, grid, par);
            if (failedInvocation || !box) return @"ERR";
            int32_t value = *(int32_t *)unbox(box);
            if (value < 0 || value == 1 || value > 536870912 || (value && (value & (value - 1)))) return @"DATA";
            board[x + 4 * y] = value;
        }
    }
    // The game keeps spawning 2s, so every 2 on the board is rewritten to a 4,
    // including the ones that were already there when the tweak attached.
    // writeCell reads each cell back, so the board reported below is what the
    // grid really holds. If the game's own state stops following the rewrite
    // (its move disagrees with our prediction over and over) the whole route is
    // switched off further down.
    if (converting) {
        BOOL rewritten = NO;
        for (int i = 0; i < 16 && converting; i++) {
            if (board[i] != 2) continue;
            int x = i % 4, y = i / 4;
            if (writeCell(grid, x, y, 4)) {
                board[i] = 4;
                rewritten = YES;
            } else {
                converting = 0;
                solver_set_spawn_value(0);
                logAuto(@"[2048-auto] grid write failed; spawns stay 2/4");
            }
        }
        if (rewritten && viewRefresh) {
            void *view = call(viewInstance, NULL, NULL);
            if (view && !failedInvocation) call(viewRefresh, view, NULL);
            if (!refreshLogged) {
                refreshLogged = 1;
                if (diagEnabled) logAuto(@"[2048-auto] view redraw called");
            }
        }
    }
    for (int i = 0; i < 16; i++) out->board[i] = board[i];
    trackProgress(grid, board, mgr, game);
    // The game may put the panel back a frame later, so sweep a couple of times.
    if (overlayHidesLeft > 0) {
        overlayHidesLeft--;
        hideLoseScreen(NO);
        if (overlayHidesLeft == 58) logFrame("sweep");
    }
    if (restartPending) {
        restartPending = 0;
        int tiles = 0;
        for (int i = 0; i < 16; i++)
            if (board[i]) tiles++;
        logAuto(@"[2048-auto] restart took effect: %d tiles", tiles);
        if (restartGood < 0) {
            restartGood = restartSlot;
            logAuto(@"[2048-auto] restart entry %d kept", restartGood + 1);
        }
        void *view = call(viewInstance, NULL, NULL);
        if (view && !failedInvocation && viewRefresh) call(viewRefresh, view, NULL);
        hideLoseScreen(YES);
        logFrame("after hide");
        // The game shows the screen again once its own game over animation has
        // finished, so keep watching for a while. Only the lose screen is
        // touched, so this costs nothing on screen.
        overlayHidesLeft = 60;
    }
    noteGameOver(board, mgr, game);
    if (diagLeft > 0) {
        diagLeft--;
        logBoard(1, board);
    }

    probeSpawn(mgr, grid);
    if (fourOwner == FIELD_GAME_MANAGER) applyFour(FIELD_GAME_MANAGER, mgr);
    if (fourOwner == FIELD_GRID) applyFour(FIELD_GRID, grid);
    if (haveExpected) {
        haveExpected = NO;
        int added = 0, at = -1;
        for (int i = 0; i < 16; i++)
            if (expected[i] == 0 && out->board[i] != 0) {
                added++;
                at = i;
            } else if (out->board[i] != expected[i])
                added = 99;
        // 出現位置の集計: 予測盤面で空いていたマスが候補になる。
        if (added == 1 && at >= 0) {
            spawnCount[at]++;
            for (int i = 0; i < 16; i++)
                if (!expected[i]) spawnChance[i]++;
        } else {
            spawnMiss++;
        }
        if (converting && diagLeft > 0) logBoard(2, expected);
        // A mismatch between the prediction and the board is no longer treated
        // as "the game ignores the rewrite": playing by hand or restarting a
        // game between our move and the read looks exactly the same. The
        // rewrite is switched off only when a write cannot be read back.
        if (added == 1 && at >= 0 && fourOwner) {
            if (out->board[at] == 2)
                revertFour(mgr, grid);
            else if (out->board[at] == 4 && ++fourSpawns == 20)
                logAuto(@"[2048-auto] 20 spawns, all 4s: forcing works");
        }
    }

    out->manager = (uintptr_t)mgr;
    out->game = (uintptr_t)game;
    out->grid = (uintptr_t)grid;
    return @"OK";
}

BOOL Auto2048GameOver(void) { return gameOverLogged ? YES : NO; }

// Starts a new game after a dead end. Returns "ON" when the game was asked to
// restart, "NO" when there was nothing to do. The caller re-reads the board on
// the next tick, so a restart that silently fails simply comes back as another
// game over and is retried.
NSString *Auto2048Restart(void) {
    if (!initEngine()) return initStatus;
    if (!gameOverLogged) return @"NO";
    failedInvocation = NO;
    void *args[] = {gmType};
    void *mgr = call(findObj, NULL, args);
    if (failedInvocation || !mgr) return @"NO";
    void *game = NULL;
    field_value(mgr, currentField, &game);
    if (failedInvocation) return @"NO";
    findRestart(game);
    if (!restartCount) {
        logAuto(@"[2048-auto] restart method not found");
        return @"NO";
    }
    int slot = restartGood >= 0 ? restartGood : (restartIndex++ % restartCount);
    restartSlot = slot;
    const M *m = restartList[slot];
    if (!m) return @"NO";
    void *ret = call(m, restartListOnGame[slot] ? game : mgr, NULL);
    if (failedInvocation) return @"NO";
    // A coroutine has to be started; invoking it alone does nothing.
    if (ret && method_ret && type_get_name) {
        const void *rt = method_ret(m);
        const char *tn = rt ? type_get_name(rt) : NULL;
        if (tn && strstr(tn, "IEnumerator")) {
            const M *sc = findStartCoroutine();
            if (sc) {
                void *par[] = {ret};
                call(sc, mgr, par);
                logAuto(@"[2048-auto] restart: coroutine started");
            } else {
                logAuto(@"[2048-auto] restart: coroutine not startable");
            }
        }
    }
    restartPending = 1;
    // The next game over is a different game, so allow it to be written out.
    gameOverLogged = 0;
    haveExpected = NO;
    logAuto(@"[2048-auto] restart attempt %d of %d", slot + 1, restartCount);
    return @"ON";
}

NSString *Auto2048Apply(const Auto2048Snapshot *previous, int dir) {
    if (!previous || dir < -1 || dir > 3) return @"ERR";

    Auto2048Snapshot now;
    NSString *status = Auto2048Read(&now);
    if (![status isEqualToString:@"OK"]) return status;

    if (now.manager != previous->manager || now.game != previous->game || now.grid != previous->grid ||
        memcmp(now.board, previous->board, sizeof(now.board)))
        return @"STALE";

    if (dir < 0) return @"END";

    int32_t after[16];
    if (!solver_move(now.board, dir, after)) return @"STALE";

    Vec2 directions[] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
    Vec2 v = directions[dir];
    void *par[] = {&v};
    call(swipe, (void *)now.manager, par);
    memcpy(expected, after, sizeof(expected));
    haveExpected = YES;
    if (failedInvocation) return @"ERR";
    moveCount++;
    return @"ON";
}
