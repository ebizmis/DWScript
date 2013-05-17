unit dwsLinqJson;

interface
uses
   Classes, Generics.Defaults, Generics.Collections,
   dwsXPlatform, dwsLinq, dwsExprs, dwsSymbols, dwsConstExprs,
   dwsMethodExprs, dwsCompiler, dwsCoreExprs, dwsErrors, dwsRelExprs,
   dwsJson, dwsUtils;

type
   TLinqJsonExtension = class(TComponent)
   private
      FLinqFactory: TdwsLinqFactory;
      procedure SetLinqFactory(const Value: TdwsLinqFactory);
   public
      property LinqFactory: TdwsLinqFactory read FLinqFactory write SetLinqFactory;
   end;

   TLinqJsonFactory = class(TInterfacedObject, ILinqQueryBuilder)
   private
      FJsonSymbol: TTypeSymbol;
      FCompiler: TdwsCompiler;

      function From(value: TTypedExpr; base: TDataSymbol): TTypedExpr;
      function Join(base: TTypedExpr; value: TSqlJoinExpr): TTypedExpr;
      function Where(from: TTypedExpr; list: TSqlList): TTypedExpr;
      function Group(from: TTypedExpr; list: TSqlList): TTypedExpr;
      function Order(from: TTypedExpr; list: TSqlList): TTypedExpr;
      function Select(from: TTypedExpr; list: TSqlList): TTypedExpr;
      function Into(base: TTypedExpr; targetFunc: TFuncPtrExpr; aPos: TScriptPos): TTypedExpr;
      function Distinct(from: TTypedExpr): TTypedExpr;
      procedure Finalize(From: TTypedExpr);
      function NeedsDot: boolean;
   public
      constructor Create(compiler: TdwsCompiler);
   end;

   TJsonExpr = class(TTypedExpr)
   public
      function EvalAsJson(exec : TdwsExecution): TdwsJsonValue; virtual; abstract;
      function Eval(exec : TdwsExecution) : Variant; override;
   end;

   TJsonFromExpr = class(TJsonExpr)
   private
      FBase: TTypedExpr;
   public
      constructor Create(base: TDataExpr);
      destructor Destroy; override;
      function EvalAsJson(exec : TdwsExecution): TdwsJsonValue; override;
   end;

   TJsonFilter = class(TJsonExpr)
   private
      FBase: TJsonExpr;
      FFilters: TSqlList;
   public
      constructor Create(base: TJsonExpr; list: TSqlList);
      destructor Destroy; override;
   end;

   TJsonWhereFilter = class(TJsonFilter)
   private
      function MatchFilter(filter: TTypedExpr; value: TdwsJsonValue; exec: TdwsExecution): boolean;
   public
      function EvalAsJson(exec : TdwsExecution): TdwsJsonValue; override;
   end;

   TJsonGroupFilter = class(TJsonFilter)
   private type
      TdwsJSONValueClass = class of TdwsJSONValue;
   private
      function GroupObjects(arr: TdwsJsonArray): TdwsJsonObject;
      function FindGroup(var current: TdwsJsonObject; elem: TdwsJsonObject;
        filter: TSqlIdentifier): boolean;
      procedure AddGroupObject(current, elem: TdwsJsonObject;
        filter: TSqlIdentifier);
      function SubCategory(current, elem: TdwsJsonObject; filter: TSqlIdentifier;
        newCat: TdwsJSONValueClass): TdwsJsonValue;
   public
      function EvalAsJson(exec : TdwsExecution): TdwsJsonValue; override;
   end;

   TJsonOrderFilter = class(TJsonFilter)
   private type
      TJsonSorter = class(TInterfacedObject, IComparer<TdwsJsonValue>)
      private
         FFilters: TSqlList;
         function CompareObjectStep(const Left, Right: TdwsJSONObject; filter: TSqlIdentifier): Integer;
         function CompareObjects(const Left, Right: TdwsJSONObject): Integer;
         function Compare(const Left, Right: TdwsJsonValue): Integer;
      public
         constructor Create(filters: TSqlList);
      end;
   private
      procedure SortJsonArray(arr: TdwsJsonArray);
   public
      function EvalAsJson(exec : TdwsExecution): TdwsJsonValue; override;
   end;

   TJsonSelectFilter = class(TJsonFilter)
   private
      procedure SelectFilter(arr: TdwsJsonArray);
      procedure ApplyFilter(objects: TObjectList<TdwsJSONObject>);
      procedure SelectGroupFilter(obj: TdwsJSONObject);
   public
      function EvalAsJson(exec : TdwsExecution): TdwsJsonValue; override;
   end;

   TJsonIntoFilter = class(TTypedExpr)
   private
      FBase: TJsonExpr;
      FInto: TFuncPtrExpr;
      FData: TDataSymbol;
      FAssign: TAssignExpr;
   public
      constructor Create(base: TJsonExpr; targetFunc: TFuncPtrExpr; compiler: TdwsCompiler; aPos: TScriptPos);
      destructor Destroy; override;
      function Eval(exec : TdwsExecution): variant; override;
   end;

implementation
uses
   Variants, SysUtils,
   dwsJsonConnector;

{ TLinqJsonFactory }

constructor TLinqJsonFactory.Create(compiler: TdwsCompiler);
begin
   FCompiler := compiler;
   FJsonSymbol := compiler.CurrentProg.Table.FindTypeSymbol('JSONVariant', cvMagic);
end;

function TLinqJsonFactory.NeedsDot: boolean;
begin
   result := false;
end;

function TLinqJsonFactory.From(value: TTypedExpr; base: TDataSymbol): TTypedExpr;
begin
   if not (value is TDataExpr) and (value.Typ = base.Typ) then
      TdwsLinqExtension.Error(FCompiler, 'Invalid FROM value.'); //should not happen
   result := TJsonFromExpr.Create(value as TDataExpr);
   result.Typ := FJsonSymbol;
end;

function TLinqJsonFactory.Join(base: TTypedExpr; value: TSqlJoinExpr): TTypedExpr;
begin
   TdwsLinqExtension.Error(FCompiler, 'Not supported yet.');
   result := nil;
end;

function TLinqJsonFactory.Where(from: TTypedExpr; list: TSqlList): TTypedExpr;
begin
   result := TJsonWhereFilter.Create(from as TJsonExpr, list);
end;

function TLinqJsonFactory.Group(from: TTypedExpr; list: TSqlList): TTypedExpr;
begin
   result := TJsonGroupFilter.Create(from as TJsonExpr, list);
end;

function TLinqJsonFactory.Order(from: TTypedExpr; list: TSqlList): TTypedExpr;
var
   group: TJsonGroupFilter;
begin
   if from.ClassType = TJsonGroupFilter then
   begin
      group := TJsonGroupFilter(from);
      result := TJsonOrderFilter.Create(group.FBase, list);
      group.FBase := TJsonOrderFilter(result);
      result := group;
   end
   else result := TJsonOrderFilter.Create(from as TJsonExpr, list);
end;

function TLinqJsonFactory.Distinct(from: TTypedExpr): TTypedExpr;
begin
   FCompiler.Msgs.AddCompilerWarning(FCompiler.Tokenizer.CurrentPos, 'dwsLinq: Distinct is not supported on JSON data');
   result := from;
end;

function TLinqJsonFactory.Select(from: TTypedExpr; list: TSqlList): TTypedExpr;
begin
   result := TJsonSelectFilter.Create(from as TJsonExpr, list);
end;

function TLinqJsonFactory.Into(base: TTypedExpr; targetFunc: TFuncPtrExpr; aPos: TScriptPos): TTypedExpr;
begin
   result := TJsonIntoFilter.Create(base as TJsonExpr, targetFunc, FCompiler, aPos)
end;

procedure TLinqJsonFactory.Finalize(From: TTypedExpr);
begin
end;

{ TJsonExpr }

function TJsonExpr.Eval(exec: TdwsExecution): Variant;
begin
   result := BoxedJsonValue(EvalAsJson(exec));
end;

{ TJsonFromExpr }

constructor TJsonFromExpr.Create(base: TDataExpr);
begin
   FBase := base;
   FBase.IncRefCount;
end;

destructor TJsonFromExpr.Destroy;
begin
   FBase.Free;
   inherited;
end;

function TJsonFromExpr.EvalAsJson(exec: TdwsExecution): TdwsJsonValue;
var
   value: IBoxedJsonValue;
begin
   value := IUnknown(FBase.Eval(exec)) as IBoxedJsonValue;
   result := value.Value.Clone;
end;

{ TJsonFilter }

constructor TJsonFilter.Create(base: TJsonExpr; list: TSqlList);
begin
   FBase := base;
   FFilters := list;
   FTyp := base.FTyp;
end;

destructor TJsonFilter.Destroy;
begin
   FBase.Free;
   FFilters.Free;
   inherited;
end;

{ TJsonWhereFilter }

function TJsonWhereFilter.MatchFilter(filter: TTypedExpr; value: TdwsJsonValue; exec: TdwsExecution): boolean;
var
   rel: TRelEqualVariantExpr;
   sub: TdwsJsonValue;
begin
   if filter.ClassType = TRelEqualVariantExpr then
   begin
      rel := TRelEqualVariantExpr(filter);
      sub := value.Items[(rel.Left as TSqlIdentifier).Value];
      result := sub.Value.AsVariant = rel.Right.Eval(exec);
   end
   else if filter.ClassType = TRelGreaterVariantExpr then
   begin
      rel := TRelEqualVariantExpr(filter);
      sub := value.Items[(rel.Left as TSqlIdentifier).Value];
      result := sub.Value.AsVariant > rel.Right.Eval(exec);
   end
   else begin
      assert(false);
      result := false;
   end;
end;

function TJsonWhereFilter.EvalAsJson(exec: TdwsExecution): TdwsJsonValue;
var
   jsonValue, elem: TdwsJSONValue;
   i, j: Integer;
   match: boolean;
begin
   jsonValue := FBase.EvalAsJson(exec);
   try
      result := TdwsJSONArray.Create;
      try
         for i := 0 to jsonValue.ElementCount - 1 do
         begin
            elem := jsonValue.Elements[i];
            match := true;
            for j := 0 to FFilters.Count - 1 do
              if not MatchFilter(TTypedExpr(FFilters[j]), elem, exec) then
              begin
                 match := false;
                 break
              end;
            if match then
               TdwsJsonArray(result).Add(elem.Clone);
         end;
      except
         result.free;
         raise;
      end;
   finally
      jsonValue.Free;
   end;
end;

{ TJsonOrderFilter }

function TJsonOrderFilter.EvalAsJson(exec: TdwsExecution): TdwsJsonValue;
begin
   result := FBase.EvalAsJson(exec);
   if result.ClassType = TdwsJSONArray then
      SortJsonArray(TdwsJSONArray(result));
end;

procedure TJsonOrderFilter.SortJsonArray(arr: TdwsJsonArray);
var
   list: TArray<TdwsJsonValue>;
   i: Integer;
   sorter: TJsonSorter;
begin
   SetLength(list, arr.ElementCount);
   for i := High(list) downto 0 do
      list[i] := arr.Elements[i];
   sorter := TJsonSorter.Create(FFilters);
   try
      TArray.Sort<TdwsJSONValue>(list, sorter);
   finally
      sorter.Free;
   end;
   for i := High(list) downto 0 do
      list[i].IncRefCount;
   arr.Clear;
   for i := 0 to High(list) do
      arr.add(list[i]);
end;

{ TJsonOrderFilter.TJsonSorter }

constructor TJsonOrderFilter.TJsonSorter.Create(filters: TSqlList);
begin
   FFilters := filters;
end;

function TJsonOrderFilter.TJsonSorter.CompareObjectStep(const Left, Right: TdwsJSONObject;
  filter: TSqlIdentifier): Integer;
var
   elemName: string;
   l, r: integer;
   lElem, rElem: TdwsJsonValue;
   rel: TVariantRelationship;
begin
   elemName := filter.Data[0];
   lElem := left.Items[elemName];
   rElem := right.Items[elemName];
   if (lElem = nil) or not lElem.IsImmediateValue then
      l := -MAXINT
   else l := 0;
   if (rElem = nil) or not rElem.IsImmediateValue then
      r := -MAXINT
   else r := 0;

   if (l = 0) and (r = 0) then
   begin
      rel := VarCompareValue(lElem.Value.AsVariant, lElem.Value.AsVariant);
      case rel of
         vrEqual: result := 0;
         vrLessThan, vrNotEqual: result := -1;
         vrGreaterThan: result := 1;
         else raise Exception.Create('Invalid variant comparison');
      end;
      if StrEndsWith(filter.Value, 'desc') then
         result := -result;
   end
   else result := l - r;
end;

function TJsonOrderFilter.TJsonSorter.CompareObjects(const Left, Right: TdwsJSONObject): Integer;
var
   i: integer;
begin
   result := 0;
   for i := 0 to FFilters.Count - 1 do
   begin
      result := CompareObjectStep(left, right, FFilters[i] as TSqlIdentifier);
      if result <> 0 then
         Exit;
   end;
end;

function TJsonOrderFilter.TJsonSorter.Compare(const Left, Right: TdwsJsonValue): Integer;
var
   l, r: integer;
begin
   if left is TdwsJSONObject then
      l := 0
   else l := -MAXINT;
   if right is TdwsJSONObject then
      r := 0
   else r := -MAXINT;
   if (l = 0) and (r = 0) then
      result := CompareObjects(TdwsJSONObject(left), TdwsJSONObject(right))
   else result := l - r;
end;

{ TJsonGroupFilter }

function TJsonGroupFilter.SubCategory(current, elem: TdwsJsonObject;
  filter: TSqlIdentifier; newCat: TdwsJSONValueClass): TdwsJsonValue;
var
   category: TdwsJsonObject;
   categorizer: TdwsJsonValue;
   catName: string;
begin
   categorizer := elem.Items[filter.Value];
   if (categorizer = nil) or not categorizer.IsImmediateValue then
      Exit(nil);
   catName := categorizer.Value.AsString;
   category := current.Items[filter.Value] as TdwsJSONObject;
   if category = nil then
      category := current.AddObject(filter.Value);
   result := category.Items[catName];
   if result = nil then
   begin
      if newCat = nil then
         Exit(nil);
      category.Add(catName, newCat.Create);
      result := category.Items[catName];
   end;
   assert(result.ClassType = newCat);
end;

function TJsonGroupFilter.FindGroup(var current: TdwsJsonObject; elem: TdwsJsonObject;
  filter: TSqlIdentifier): boolean;
var
   category: TdwsJsonObject;
begin
   category := SubCategory(current, elem, filter, TdwsJsonObject) as TdwsJsonObject;
   if category = nil then
      result := false
   else begin
      result := true;
      current := category;
   end;
end;

procedure TJsonGroupFilter.AddGroupObject(current: TdwsJsonObject; elem: TdwsJsonObject;
  filter: TSqlIdentifier);
const GROUP_FAIL = 'GROUP_FAIL';
var
   fail: boolean;
   category: TdwsJSONArray;
begin
   category := nil;
   fail := filter = nil;
   if not fail then
   begin
      category := SubCategory(current, elem, filter, TdwsJsonArray) as TdwsJsonArray;
      fail := category = nil;
   end;
   if fail then
   begin
      category := current.Items[GROUP_FAIL] as TdwsJsonArray;
      if category = nil then
         category := current.AddArray(GROUP_FAIL);
   end;
   category.Add(elem);
end;

function TJsonGroupFilter.GroupObjects(arr: TdwsJsonArray): TdwsJsonObject;
var
   current: TdwsJsonObject;
   elem: TdwsJSONValue;
   i, j: integer;
   fail: boolean;
begin
   result := TdwsJsonObject.Create;
   try
      for i := 0 to arr.ElementCount - 1 do
      begin
         current := result;
         elem := arr.Elements[i];
         fail := elem.ClassType <> TdwsJSONObject;
         if not fail then
            for j := 0 to FFilters.Count - 2 do
            begin
               fail := FindGroup(current, TdwsJSONObject(elem), FFilters[i] as TSqlIdentifier);
               if fail then
                  Break;
            end;
         if fail then
            AddGroupObject(current, TdwsJsonObject(elem.Clone), nil)
         else AddGroupObject(current, TdwsJsonObject(elem.Clone), FFilters[FFilters.Count - 1] as TSqlIdentifier);
      end;
   except
      result.Free;
      raise;
   end;
end;

function TJsonGroupFilter.EvalAsJson(exec: TdwsExecution): TdwsJsonValue;
var
   baseValue: TdwsJsonValue;
begin
   baseValue := FBase.EvalAsJson(exec);
   if baseValue.ClassType = TdwsJsonArray then
   begin
      result := GroupObjects(TdwsJsonArray(baseValue));
      baseValue.Free;
   end
   else result := baseValue;
end;

{ TJsonSelectFilter }

procedure TJsonSelectFilter.ApplyFilter(objects: TObjectList<TdwsJSONObject>);
var
   i, j: integer;
   obj: TdwsJSONObject;
   sl: TStringList;
begin
   sl := TStringList.Create;
   try
      for i := 0 to FFilters.count - 1 do
         sl.add(UpperCase((FFilters[i] as TSqlIdentifier).value));

      for i := 0 to objects.Count - 1 do
      begin
         obj := objects[i];
         for j := obj.ElementCount - 1 downto 0 do
            if sl.IndexOf(UpperCase(obj.Names[j])) = -1 then
               obj.Elements[j].Free;
      end;
   finally
      sl.Free;
   end;
end;

procedure CollectArrays(obj: TdwsJSONObject; arrays: TObjectList<TdwsJSONArray>);
var
   i: integer;
   elem: TdwsJSONValue;
begin
   for i := 0 to obj.ElementCount - 1 do
   begin
      elem := obj.Elements[i];
      if elem.ClassType = TdwsJSONObject then
         CollectArrays(TdwsJSONObject(elem), arrays)
      else if elem.ClassType = TdwsJSONArray then
      begin
         elem.IncRefCount;
         arrays.Add(TdwsJSONArray(elem));
      end;
   end;
end;

function CollectObjects(arrays: TObjectList<TdwsJSONArray>): TObjectList<TdwsJSONObject>;
var
   arr: TdwsJSONArray;
   elem: TdwsJSONValue;
   i, j: integer;
begin
   result := TObjectList<TdwsJSONObject>.Create;
   try
      for i := 0 to arrays.Count - 1 do
      begin
         arr := arrays[i];
         for j := 0 to arr.ElementCount - 1 do
         begin
            elem := arr.Elements[j];
            if elem.ClassType = TdwsJSONObject then
            begin
               elem.IncRefCount;
               result.add(TdwsJSONObject(elem));
            end;
         end;
      end;
   except
      result.Free;
      raise;
   end;
end;

procedure TJsonSelectFilter.SelectGroupFilter(obj: TdwsJSONObject);
var
   arrays: TObjectList<TdwsJSONArray>;
   objects: TObjectList<TdwsJSONObject>;
begin
   objects := nil;
   arrays := TObjectList<TdwsJSONArray>.Create;
   try
      CollectArrays(obj, arrays);
      objects := CollectObjects(arrays);
      ApplyFilter(objects);
   finally
      arrays.Free;
      objects.Free;
   end;
end;

procedure TJsonSelectFilter.SelectFilter(arr: TdwsJsonArray);
var
   objects: TObjectList<TdwsJSONObject>;
   i: integer;
   elem: TdwsJSONValue;
begin
   objects := TObjectList<TdwsJSONObject>.Create;
   try
      for i := 0 to objects.Count - 1 do
      begin
         elem := arr.Elements[i];
         if elem.ClassType = TdwsJSONObject then
         begin
            elem.IncRefCount;
            objects.Add(TdwsJSONObject(elem));
         end;
      end;
      ApplyFilter(objects);
   finally
      objects.Free;
   end;
end;

function TJsonSelectFilter.EvalAsJson(exec: TdwsExecution): TdwsJsonValue;
var
   baseValue: TdwsJsonValue;
begin
   baseValue := FBase.EvalAsJson(exec);
   if baseValue.ClassType = TdwsJSONArray then
      SelectFilter(TdwsJSONArray(baseValue))
   else if (baseValue.ClassType = TdwsJSONObject) and (FBase.ClassType = TJsonGroupFilter) then
      SelectGroupFilter(TdwsJSONObject(baseValue));
   result := baseValue;
end;

{ TJsonIntoFilter }

constructor TJsonIntoFilter.Create(base: TJsonExpr; targetFunc: TFuncPtrExpr;
  compiler: TdwsCompiler; aPos: TScriptPos);
var
   prog: TdwsProgram;
   jsonVar: TVarExpr;
begin
   inherited Create;
   FBase := base;
   FInto := targetFunc;
   FTyp := Finto.typ;
   prog := compiler.CurrentProg;
   FData := TDataSymbol.Create('', FBase.FTyp);
   FData.AllocateStackAddr(prog.Table.AddrGenerator);
   jsonVar := TVarExpr.Create(prog, FData);
   FBase.IncRefCount;
   FAssign := TAssignExpr.Create(prog, aPos, jsonVar, FBase);
   jsonVar.IncRefCount;
   FInto.AddArg(jsonVar);
   FInto.Initialize(prog);
end;

destructor TJsonIntoFilter.Destroy;
begin
   FInto.Free;
   FData.Free;
   FAssign.Free;
   FBase.Free;
   inherited Destroy;
end;

function TJsonIntoFilter.Eval(exec: TdwsExecution): variant;
begin
   FAssign.EvalNoResult(exec);
   FInto.EvalAsVariant(exec, result);
end;

{ Classless }

function LinqJsonFactory(compiler: TdwsCompiler; symbol: TTypeSymbol): ILinqQueryBuilder;
var
   factory: TLinqJsonFactory;
begin
   factory := TLinqJsonFactory.Create(compiler);
   if symbol.IsCompatible(factory.FJsonSymbol) then
      result := factory
   else begin
      result := nil;
      factory.Free;
   end;
end;

{ TLinqJsonExtension }

procedure TLinqJsonExtension.SetLinqFactory(const Value: TdwsLinqFactory);
begin
   FLinqFactory := Value;
   if assigned(FLinqFactory) then
      FLinqFactory.RegisterSource(@LinqJsonFactory);
end;

end.