#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "Solver.h"
#import "Engine.h"
#include <stdint.h>
#include <string.h>

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

static C *gmClass, *regularClass, *gridClass, *viewClass;
static void *gmType;
static F *currentField, *viewGridField;
static const M *findObj, *active, *getGrid, *getSize, *getCell, *swipe, *viewInstance, *isMoving;
static BOOL ready = NO, failedInvocation = NO;
static NSString *initStatus = @"I_START";

#define LOAD(p, n)                                       \
    do {                                                 \
        *(void **)(&(p)) = dlsym(RTLD_DEFAULT, n);       \
        if (!(p)) {                                      \
            initStatus = @"I_API";                       \
            NSLog(@"[2048-auto] API missing: %s", n);    \
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
        NSLog(@"[2048-auto] managed exception");
    }
    return r;
}

static BOOL initEngine(void) {
    if (ready) return YES;

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

    *(void **)(&class_fields) = dlsym(RTLD_DEFAULT, "il2cpp_class_get_fields");
    *(void **)(&field_name) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_name");
    *(void **)(&field_type) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_type");
    *(void **)(&type_get_name) = dlsym(RTLD_DEFAULT, "il2cpp_type_get_name");
    *(void **)(&field_set) = dlsym(RTLD_DEFAULT, "il2cpp_field_set_value");
    *(void **)(&field_flags) = dlsym(RTLD_DEFAULT, "il2cpp_field_get_flags");

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
        NSLog(@"[2048-auto] class manager=%p regular=%p grid=%p view=%p mode=%p obj=%p", gmClass, regularClass,
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
        NSLog(@"[2048-auto] type=%p fields=%p,%p methods=%p,%p,%p,%p,%p,%p,%p,%p", gmType, currentField,
              viewGridField, findObj, active, getGrid, getSize, getCell, swipe, viewInstance, isMoving);
        return NO;
    }

    NSLog(@"[2048-auto] IL2CPP ready");
    ready = YES;
    return YES;
}

typedef struct {
    int32_t x, y;
} Vec2;

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
static int convertingStrikes;

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
        if (containsFour(n)) NSLog(@"[2048-auto] %s.%s = %g (spawn candidate)", label, n ? n : "?", v);
        if (!fourOwner && containsFour(n) && v >= 0.0f && v <= 1.0f) {
            fourField = (F *)f;
            fourOwner = owner;
            fourOldValue = v;
            if (v < 1.0f && field_set) {
                float one = 1.0f;
                field_set(target, (F *)f, &one);
            }
            NSLog(@"[2048-auto] spawn forced to 4 via %s.%s (%g -> 1)", label, n ? n : "?", v);
        }
    }
}

// Names only, so that a log from a device shows where the tile value is picked
// if the field route turns out to be a dead end.
static BOOL interestingName(const char *n) {
    static const char *keys[] = {"spawn", "random", "addtile", "newtile", "pick"};
    if (!n) return NO;
    for (int k = 0; k < 5; k++) {
        size_t len = strlen(keys[k]);
        for (const char *p = n; *p; p++) {
            size_t i = 0;
            while (i < len && p[i]) {
                char c = (p[i] >= 'A' && p[i] <= 'Z') ? (char)(p[i] - 'A' + 'a') : p[i];
                if (c != keys[k][i]) break;
                i++;
            }
            if (i == len) return YES;
        }
    }
    return NO;
}

// Field names and types, for the next round of guesswork when neither route
// works. Names may be hidden ("<private>") in release builds.
static void dumpFieldNames(C *c, const char *label) {
    if (!c || !class_fields || !field_name || !field_type || !type_get_name) return;
    void *it = NULL;
    const F *f;
    while ((f = class_fields(c, &it))) {
        const char *n = field_name(f);
        const void *t = field_type(f);
        const char *tn = t ? type_get_name(t) : NULL;
        NSLog(@"[2048-auto] %s field: %s %s", label, n ? n : "?", tn ? tn : "?");
    }
}

static void dumpMethodNames(C *c, const char *label) {
    if (!c || !class_methods || !method_name) return;
    void *it = NULL;
    const M *m;
    while ((m = class_methods(c, &it)))
        if (interestingName(method_name(m))) NSLog(@"[2048-auto] %s method: %s", label, method_name(m));
}

static void probeSpawn(void *mgr, void *grid) {
    if (fourProbeDone) return;
    fourProbeDone = YES;
    probeFields(gmClass, mgr, FIELD_GAME_MANAGER, "GameManager");
    probeFields(gridClass, grid, FIELD_GRID, "Grid");
    if (!fourOwner) {
        dumpMethodNames(gmClass, "GameManager");
        dumpMethodNames(gridClass, "Grid");
        setCellMethod = findSetter();
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
            NSLog(@"[2048-auto] grid setter works; spawned 2s are turned into 4s");
        } else {
            NSLog(@"[2048-auto] no four-chance field and no grid setter; spawns stay 2/4");
            dumpFieldNames(gmClass, "GameManager");
            dumpFieldNames(gridClass, "Grid");
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
    NSLog(@"[2048-auto] a 2 spawned after forcing; reverting to 2/4");
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
    if (failedInvocation || !box || !*(uint8_t *)unbox(box)) return @"PAUSE";

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
    int twos = 0;
    int firstTwo = -1;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            Vec2 v = {x, y};
            void *par[] = {&v};
            box = call(getCell, grid, par);
            if (failedInvocation || !box) return @"ERR";
            int32_t value = *(int32_t *)unbox(box);
            if (value < 0 || value == 1 || value > 536870912 || (value && (value & (value - 1)))) return @"DATA";
            if (value == 2) {
                twos++;
                if (firstTwo < 0) firstTwo = x + 4 * y;
            }
            board[x + 4 * y] = value;
        }
    }
    // The game still spawns 2s; replace the one it just added with a 4. Only a
    // single 2 is rewritten, because that is what one move can produce. More
    // than that means either a board we attached to mid-game or the game
    // putting our 4s back, so nothing is written and we watch a few moves
    // before giving up. writeCell reads the cell back, so the board reported
    // below is always what the grid really holds.
    if (converting) {
        if (twos <= 1) {
            convertingStrikes = 0;
            if (twos == 1) {
                int at = firstTwo;
                if (writeCell(grid, at % 4, at / 4, 4))
                    board[at] = 4;
                else {
                    converting = 0;
                    solver_set_spawn_value(0);
                    NSLog(@"[2048-auto] grid write failed; spawns stay 2/4");
                }
            }
        } else if (++convertingStrikes >= 3) {
            converting = 0;
            solver_set_spawn_value(0);
            NSLog(@"[2048-auto] 2s came back after rewriting; spawns stay 2/4");
        }
    }
    for (int i = 0; i < 16; i++) out->board[i] = board[i];

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
        if (added == 1 && at >= 0 && fourOwner) {
            if (out->board[at] == 2)
                revertFour(mgr, grid);
            else if (out->board[at] == 4 && ++fourSpawns == 20)
                NSLog(@"[2048-auto] 20 spawns, all 4s: forcing works");
        }
    }

    out->manager = (uintptr_t)mgr;
    out->game = (uintptr_t)game;
    out->grid = (uintptr_t)grid;
    return @"OK";
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
    return failedInvocation ? @"ERR" : @"ON";
}
