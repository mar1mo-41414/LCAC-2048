#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "Solver.h"
#import "Engine.h"
#include <stdint.h>
#include <string.h>

typedef void C; typedef void M; typedef void F;
static void *(*domain_get)(void); static const void **(*assemblies)(const void*,size_t*);
static const void *(*image)(const void*); static C *(*klass)(const void*,const char*,const char*);
static C *(*object_class)(void*); static const void *(*class_type)(C*); static void *(*type_object)(const void*);
static const M *(*class_methods)(C*,void**); static const char *(*method_name)(const M*);
static uint32_t (*param_count)(const M*); static bool (*method_generic)(const M*);
static const M *(*method)(C*,const char*,int); static F *(*field)(C*,const char*);
static void (*field_value)(void*,F*,void*); static void *(*invoke)(const M*,void*,void**,void**);
static void *(*unbox)(void*); static const void *(*corlib)(void);
static C *gmClass,*regularClass,*gridClass,*viewClass; static void *gmType;
static F *currentField,*viewGridField;
static const M *findObj,*active,*getGrid,*getSize,*getCell,*swipe,*viewInstance,*isMoving;
static BOOL ready=NO, failedInvocation=NO;
static NSString *initStatus = @"I_START";
#define LOAD(p,n) do { *(void **)(&(p))=dlsym(RTLD_DEFAULT,n); if(!(p)) { initStatus=@"I_API"; NSLog(@"[2048-auto] API missing: %s", n); return NO; } } while(0)
static C *findClass(const char *ns,const char *name) {
    size_t n=0; const void **a=assemblies(domain_get(),&n);
    for(size_t i=0;a && i<n;i++){const void *im=image(a[i]); C *c=im?klass(im,ns,name):NULL; if(c)return c;} return NULL;
}
static void *call(const M *m,void *obj,void **args) {
    if(!m){failedInvocation=YES;return NULL;} void *exc=NULL; void *r=invoke(m,obj,args,&exc);
    if(exc){failedInvocation=YES; NSLog(@"[2048-auto] managed exception");} return r;
}
static BOOL initEngine(void){
    if(ready)return YES;
    LOAD(domain_get,"il2cpp_domain_get"); LOAD(assemblies,"il2cpp_domain_get_assemblies"); LOAD(image,"il2cpp_assembly_get_image");
    LOAD(klass,"il2cpp_class_from_name"); LOAD(object_class,"il2cpp_object_get_class"); LOAD(class_type,"il2cpp_class_get_type");
    LOAD(type_object,"il2cpp_type_get_object"); LOAD(method,"il2cpp_class_get_method_from_name"); LOAD(field,"il2cpp_class_get_field_from_name");
    LOAD(field_value,"il2cpp_field_get_value"); LOAD(invoke,"il2cpp_runtime_invoke");
    LOAD(class_methods,"il2cpp_class_get_methods"); LOAD(method_name,"il2cpp_method_get_name");
    LOAD(param_count,"il2cpp_method_get_param_count"); LOAD(method_generic,"il2cpp_method_is_generic"); LOAD(unbox,"il2cpp_object_unbox"); LOAD(corlib,"il2cpp_get_corlib");
    if(!corlib() || !domain_get()){initStatus=@"I_UNITY";return NO;}
    gmClass=findClass("Game2048","GameManager"); regularClass=findClass("Game2048.GameModes","RegularGame");
    gridClass=findClass("","Grid"); viewClass=findClass("","GridViewManager"); C *mode=findClass("Game2048.GameModes","GameMode"); C *obj=findClass("UnityEngine","Object");
    if(!gmClass || !regularClass || !gridClass || !viewClass || !mode || !obj){initStatus=@"I_CLASS"; NSLog(@"[2048-auto] class manager=%p regular=%p grid=%p view=%p mode=%p obj=%p",gmClass,regularClass,gridClass,viewClass,mode,obj);return NO;}
    gmType=type_object(class_type(gmClass)); currentField=field(gmClass,"_currentGame"); viewGridField=field(viewClass,"_grid");
    // There is also FindFirstObjectByType<T>(FindObjectsInactive), with the same
    // name and arity. A plain name/arity lookup may select that open generic.
    // Select the non-generic (System.Type) overload as in LCAC-A.
    findObj=NULL; void *it=NULL; const M *candidate;
    while ((candidate=class_methods(obj,&it))) {
        const char *n=method_name(candidate);
        if(n && !strcmp(n,"FindFirstObjectByType") && param_count(candidate)==1 && !method_generic(candidate)) {findObj=candidate;break;}
    }
    active=method(regularClass,"get_GameActive",0);
    getGrid=method(mode,"get_Grid",0); getSize=method(gridClass,"get_Size",0); getCell=method(gridClass,"GetCellValue",1);
    swipe=method(gmClass,"HandleSwipe",1); viewInstance=method(viewClass,"get_Instance",0); isMoving=method(viewClass,"IsAnyTileMoving",0);
    if(!gmType || !currentField || !viewGridField || !findObj || !active || !getGrid || !getSize || !getCell || !swipe || !viewInstance || !isMoving){initStatus=@"I_METHOD"; NSLog(@"[2048-auto] type=%p fields=%p,%p methods=%p,%p,%p,%p,%p,%p,%p,%p", gmType,currentField,viewGridField,findObj,active,getGrid,getSize,getCell,swipe,viewInstance,isMoving); return NO;}
    NSLog(@"[2048-auto] IL2CPP ready"); ready=YES; return YES;
}
typedef struct {int32_t x,y;} Vec2;
// Returns status for UI; all calls occur on Unity's main thread. Unsupported modes do nothing.
NSString *Auto2048Read(Auto2048Snapshot *out){
    if(!out)return @"ERR";
    if(!initEngine())return initStatus;
    failedInvocation=NO; void *args[]={gmType}; void *mgr=call(findObj,NULL,args); if(failedInvocation)return @"F_EXC"; if(!mgr)return @"F_MGR";
    void *game=NULL; field_value(mgr,currentField,&game); if(!game || object_class(game)!=regularClass)return @"MODE";
    void *box=call(active,game,NULL); if(failedInvocation||!box||!*(uint8_t*)unbox(box))return @"PAUSE";
    void *grid=call(getGrid,game,NULL); if(failedInvocation)return @"G_EXC"; if(!grid)return @"G_NULL";
    void *view=call(viewInstance,NULL,NULL); if(failedInvocation)return @"V_EXC"; if(!view)return @"V_NULL";
    void *displayedGrid=NULL; field_value(view,viewGridField,&displayedGrid); if(displayedGrid!=grid)return @"V_GRID";
    box=call(isMoving,view,NULL); if(failedInvocation||!box)return @"ERR"; if(*(uint8_t*)unbox(box))return @"V_MOVE";
    box=call(getSize,grid,NULL); if(failedInvocation||!box||*(int32_t*)unbox(box)!=4)return @"SIZE";
    for(int y=0;y<4;y++)for(int x=0;x<4;x++){
        Vec2 v={x,y}; void *par[]={&v}; box=call(getCell,grid,par); if(failedInvocation||!box)return @"ERR";
        int32_t value=*(int32_t*)unbox(box); if(value<0 || value==1 || value>536870912 || (value && (value&(value-1))))return @"DATA"; out->board[x+4*y]=value;
    }
    out->manager=(uintptr_t)mgr; out->game=(uintptr_t)game; out->grid=(uintptr_t)grid;
    return @"OK";
}
NSString *Auto2048Apply(const Auto2048Snapshot *previous, int dir){
    if(!previous || dir < -1 || dir>3)return @"ERR";
    Auto2048Snapshot now; NSString *status=Auto2048Read(&now);
    if(![status isEqualToString:@"OK"])return status;
    if(now.manager!=previous->manager || now.game!=previous->game || now.grid!=previous->grid || memcmp(now.board,previous->board,sizeof(now.board)))return @"STALE";
    if(dir<0)return @"END";
    int32_t after[16]; if(!solver_move(now.board,dir,after))return @"STALE";
    Vec2 directions[]={{-1,0},{1,0},{0,-1},{0,1}}; Vec2 v=directions[dir]; void *par[]={&v}; call(swipe,(void *)now.manager,par);
    return failedInvocation?@"ERR":@"ON";
}
