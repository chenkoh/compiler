module Compile.TypeCheck (checkFunction, paramListToTParamList, eastTypeToTastType, isTypeLarge) where
import qualified Compile.MapWrap as MapWrap
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Tuple
import Data.Maybe 
import Compile.Constants

import qualified Compile.Types.EAST as E
import qualified Compile.Types.TAST as T
import Compile.Types
import Debug.Trace

type ReturnType = T.CType
type FuncMap = Map.Map Ident (T.CType, [(T.CType, T.Ident)]) -- All CTypes here are guaranteed to be basic
type TypeMap = Map.Map Ident T.CType
type StructMap = Map.Map Ident (Map.Map Ident T.CType)
type ArrayMap = Map.Map Ident T.CType
-- ScrambleMap is a map from scrambled function name to original function name
type ScrambleMap = Map.Map Ident Ident

-- FuncMap[functionName] gives a tuple of the function's return type and the arguments
-- ReturnType: is the return type of the function that we are currently typechecking
-- TypeMap: typemap[ident] is the type of an ident
-- StructMap[structName] gives you the field list of the struct

type FdefSet = Set.Set Ident

type TypeState = (FuncMap, ReturnType, TypeMap, StructMap, ScrambleMap,FdefSet)

-- When changing the type of TypeState, please change functions containing state@
getFuncMap state@(funcmap,_,_,_,_,_) = funcmap
getReturnType state@(_,returnType,_,_,_,_) = returnType
getTypeMap state@(_,_,typemap,_,_,_) = typemap
getStructMap state@(_,_,_,structmap,_,_) = structmap
getScrambleMap state@(_,_,_,_,scramblemap,_) = scramblemap
getFdefset state@(_,_,_,_,_,fdefset) = fdefset
insertIdentType :: TypeState -> E.Ident -> T.CType -> TypeState
insertIdentType state@(funcmap, returnType, typemap, structmap, scramblemap,fdefset) ident ttype =
  (funcmap, returnType, Map.insert ident ttype typemap, structmap, scramblemap,fdefset)

-- The only realy work we do here is to:
-- 1. Convert our inputs into the right types
-- 2. Check if main function is of the form int main()
checkFunction :: (FuncMap,StructMap,ScrambleMap,FdefSet) -> E.Gdecl -> T.Gdecl
checkFunction (funcmap,structmap,scramblemap,fdefset) (E.Fdefn ctype ident paramlist block) =
  let
    returnType = eastTypeToTastType ctype
    tparamlist = paramListToTParamList paramlist
    targlist = map (\(T.Param ctype ident) -> (ctype, ident)) tparamlist
    inputMap = Map.fromList (map swap targlist)
    newFuncMap = Map.insert ident (returnType, targlist) funcmap
    (newstate, tblock) = checkBlock (funcmap, returnType, inputMap, structmap, scramblemap, fdefset) block
    argtypelist = map fst targlist
    isArgLarge = any isTypeLarge argtypelist
    isReturnLarge = isTypeLarge returnType
    isReturnTypeVoidPointer = case returnType of
      CPtr t -> isTypeVoidDerivative t
      CArray t -> isTypeVoidDerivative t
      _ -> False
  in
    case (returnType, ident == (functionPrefix ++ "main"), paramlist, isArgLarge, isReturnLarge, isReturnTypeVoidPointer) of
      (_,_,_,_,_,True) -> error("Return type of function cannot be something like void[] or void*")
      (_,_,_,True,_,_) -> error("Function argument is large type")
      (_,_,_,_,True,_) -> error("Function return is large type")
      (T.CInt,True, [],_,_,False) -> T.Fdefn returnType ident tparamlist tblock
      (_, True,_,_,_,_) -> error("main is not of the form int main()")
      (_,_,_,False,False,False) -> T.Fdefn returnType ident tparamlist tblock

-- Glorified foldl wrapper for checkStmt
checkBlock :: TypeState -> E.Block ->  (TypeState, T.Block)
checkBlock state (stmt:block) =
  let
    (newState, tstmt) = checkStmt state stmt
    (finalState, finalStmt) = checkBlock newState block
  in
    (finalState, tstmt:finalStmt)
checkBlock state [] = (state, [])

checkStmt :: TypeState -> E.Stmt -> (TypeState, T.Stmt)
checkStmt state (E.Simp simp) = 
  let
    (newstate, tsimp) = checkSimp state simp
  in
    (newstate, T.Simp tsimp)
checkStmt state (E.Ctrl ctrl) = 
  -- For control blocks, the variables declared inside are not in scope once we exit the control block
  -- Thus, do not use the new state generated by the block
  let
    (_, tctrl) = checkCtrl state ctrl
  in
    (state, T.Ctrl tctrl)
checkStmt state (E.Blk block) =
  -- For blocks, the variables declared inside are not in scope once we exit the block
  -- Thus, do not use the new state generated by the block
  let
    (_, tblk) = checkBlock state block
  in
    (state, T.Blk tblk)

checkSimp :: TypeState -> E.Simp -> (TypeState, T.Simp)
checkSimp state (E.Asgn lvalue asnop expr) =
  let
    (tlvalue, lvalueType) = getLvalueType state lvalue
    (texpr, exprType) = getExpType state expr
    lvalueAndOpTypesAgree = case asnop of
      Equal -> True
      AsnOp binop ->
        (case getBinopType binop of
          IntegerBinop -> lvalueType == T.CInt
          LogicalBinop -> lvalueType == T.CBool
          PolyEqual -> error("What the fuck is a PolyEqual doing in an Asnop?")
          )
  in
    -- Obviously, the value we assign to must have the same type as the expression
    case (lvalueAndOpTypesAgree, areTypesEqualExpr lvalueType exprType, isTypeLarge lvalueType, isTypeLarge exprType) of
      (True, True, False, False) -> (state, T.Asgn tlvalue asnop texpr)
      (False, _, _, _) -> error ("Asnop binop does not match with lvalue")
      (_, False,_,_) -> error ("Asgn type mismatch: lvalue and expr types are different" ++ show lvalue ++ " = " ++ show expr)
      (_, _,True,_) -> error("lvalue is Large type")
      (_, _,_,True) -> error("expr is Large type")

checkSimp state (E.Decl ctype ident) =
  let
    ttype = eastTypeToTastType ctype
    checkedType =
      case (ttype, isTypeLarge ttype, isTypeVoidDerivative ttype) of
        (T.CNoType,_,_) -> error "Undefined Type"
        (_,_,True) -> error "Variables can't be void"
        (_,True,_) -> error "Cannot declare large type"
        (_,False,False) -> ttype
    newState = insertIdentType state ident checkedType
  in
    case checkedType of
      T.CStruct _ -> error "Cannot declare large type!!"
      _ -> (newState, T.Decl checkedType ident)

checkSimp state (E.Exp expr) = 
  let
    (texpr, exprType) = getExpType state expr
  in
    case isTypeLarge exprType of
      True -> error "Large type in Simp"
      False -> (state, T.Exp texpr)

checkCtrl :: TypeState -> E.Ctrl -> (TypeState, T.Ctrl)
checkCtrl state (E.If expr stmt1 stmt2) =
  let
    (texpr, exprType) = getExpType state expr
    (_, tstmt1) = checkStmt state stmt1
    (_, tstmt2) = checkStmt state stmt2
  in
    case (exprType) of
      T.CBool -> (state, T.If texpr tstmt1 tstmt2)
      _ -> error "If: Conditional expr in If statement is not a boolean"

checkCtrl state (E.While expr stmt) =
  let
    (texpr, exprType) = getExpType state expr
    (_, tstmt) = checkStmt state stmt
  in
    case (exprType) of
      T.CBool -> (state, T.While texpr tstmt)
      _ -> error ("While: Conditional expression in while statement is not a boolean")

checkCtrl state (E.Ret expr) =
  let
    (texpr, exprType) = getExpType state expr
    isTypeEqual = areTypesEqual (getReturnType state) exprType
  in
    case (isTypeEqual, exprType) of
      (_, T.CVoid) -> error("Void cannot perform a return")
      (True, _) -> (state, T.Ret texpr)
      (False, _) -> error ("Return type does not match")

checkCtrl state (E.RetVoid) =
  case ((getReturnType state) ==  T.CVoid) of
    True -> (state, T.RetVoid)
    False -> error("Cannot return nothing in a non-void function")

-- Given an EAST lvalue, returns a TAST lvalue, as well as the type of that lvalue
getLvalueType :: TypeState -> E.Lvalue -> (T.Lvalue, T.CType)
getLvalueType state (E.Variable ident) =
  let
    identType = getIdentType state ident
  in
    (T.Variable ident identType, identType)
getLvalueType state (E.LvalueDot lvalue ident) = 
  let
    (tlvalue, lvalueType) = getLvalueType state lvalue
    fieldType = getStructFieldType state lvalueType ident
  in
    (T.LvalueDot tlvalue ident fieldType, fieldType)
getLvalueType state (E.LvaluePointerStar lvalue) = 
  let
    (tlvalue, lvalueType) = getLvalueType state lvalue
    derefType = dereferenceType lvalueType
  in
    (T.LvaluePointerStar tlvalue derefType, derefType)
getLvalueType state (E.LvalueArrayAccess lvalue expr) = 
  let
    (tlvalue, lvalueType) = getLvalueType state lvalue
    (texpr, exprType) = getExpType state expr
    elemType = getArrayElementType lvalueType
  in
    case exprType of
      T.CInt -> (T.LvalueArrayAccess tlvalue texpr elemType, elemType)
      _ -> error("Array index is not an integer:" ++ show expr)

-- Given an EAST expression, returns a TAST expression, as well as the type of that expression
getExpType :: TypeState -> E.Exp -> (T.Exp, T.CType)
getExpType state (E.Const n) = 
  case ((-(2^32) <= n) && (n <= 2^32)) of
    True -> (T.Const n T.CInt, T.CInt)
    False -> error ("Typecheck: We hackily check for constants that are too large here." ++ show n)

getExpType state (E.CTrue)  = (T.CTrue  T.CBool, T.CBool)
getExpType state (E.CFalse) = (T.CFalse T.CBool, T.CBool)
getExpType state (E.Var ident) =
  let
    identType = getIdentType state ident
  in
    (T.Var ident identType, identType)

getExpType state (E.Unary unop expr) =
  let
    opType = getUnaryOpType unop
    (texpr, exprType) = getExpType state expr
  in
    case (opType == exprType) of
      True -> (T.Unary unop texpr exprType, exprType)
      False -> error ("Unary: Op and Expression mismatch. Op:" ++ show unop ++ " Expr:" ++ show expr)

getExpType state (E.Binary binop expr1 expr2) =
  let
    (texpr1, expr1Type) = getExpType state expr1
    (texpr2, expr2Type) = getExpType state expr2
    isPolyEqualAllowed = areTypesEqualExpr expr1Type expr2Type
    isLarge1 = isTypeLarge expr1Type
    isLarge2 = isTypeLarge expr2Type
  in
    case (getBinopType binop, expr1Type, expr2Type, isPolyEqualAllowed, isLarge1, isLarge2) of
      -- This is a PolyEqual: == !=
      (PolyEqual, _, _, True, False, False) -> (T.Binary binop texpr1 texpr2 T.CBool, T.CBool)
      (PolyEqual, _, _, False, _, _) -> error "PolyEqual: Type mismatch"
      (PolyEqual, _, _, True, _, _) -> error "PolyEqual: Large type"
      -- This is a RelEqual of integers: < > <= >=
      (RelativeEqual, T.CInt, T.CInt, _, _, _) -> (T.Binary binop texpr1 texpr2 T.CBool, T.CBool)
      (RelativeEqual, _, _, _, _, _) -> error "RelativeEqual: Type mismatch"
      -- This is a logical BinOp
      (LogicalBinop, T.CBool, T.CBool, _, _, _) -> (T.Binary binop texpr1 texpr2 T.CBool, T.CBool)
      (LogicalBinop, _, _, _, _, _) -> error "LogicalBinop: Type mismatch"
      -- This is a integer BinOp
      (IntegerBinop, T.CInt, T.CInt, _, _, _) -> (T.Binary binop texpr1 texpr2 T.CInt, T.CInt)
      (IntegerBinop, _, _, _, _, _) -> error "IntegerBinop: Type mismatch"

-- Ternary ONLY supports x ? y : z operator.
getExpType state (E.Ternary expr1 expr2 expr3) =
  let
    (texpr1, expr1Type) = getExpType state expr1
    (texpr2, expr2Type) = getExpType state expr2
    (texpr3, expr3Type) = getExpType state expr3
    resultingType = combineTypes expr2Type expr3Type
  in
    case (expr1Type, expr2Type, areTypesEqualExpr expr2Type expr3Type, isTypeLarge expr2Type) of
      (_,_,_,True) -> error "Large type in conditional ? : expression"
      (T.CBool, T.CVoid, _, _) -> error "No voids in subexpressions"
      -- We may assume expr2Type == expr3Type in the line below, so we just return expr2Type
      (T.CBool, _, True, False) -> (T.Ternary texpr1 texpr2 texpr3 resultingType, resultingType)
      (T.CBool, _, False, _) ->  error "Ternary: Second and third expr mismatch"
      (_, _, _, _) -> error "Ternary: First expr must be a boolean"

getExpType state (E.Call ident args) =
  let
    tArgsAndTypes::[(T.Exp, T.CType)]
    tArgsAndTypes = map (getExpType state) args
    targs = map fst tArgsAndTypes
    targtypes = map snd tArgsAndTypes
    returnType = checkCall state targtypes ident
    scrambleMap = getScrambleMap state
    typeMap = getTypeMap state
    -- Look back and get real function name so we know if it's shadowed.
    realFunctionName = scrambleMap Map.! ident
    fdefset = getFdefset state
  in
    case (Map.member realFunctionName typeMap, Set.member ident fdefset, ident) of
      (True,_,_) -> error("getExpType call: Function has been shadowed by variable:" ++ show ident ++ show realFunctionName)
      (False,True,_) -> (T.Call ident targs returnType, returnType)
      (False,_,"abort") -> (T.Call ident targs returnType, returnType)
      (_,_,"_abort") -> case (machinePrefix == "_") of
        True -> (T.Call ident targs returnType, returnType)
        False -> error("Shit, cannot find function in fdefset:" ++ ident ++ ":" ++ show fdefset)
      (_,_,_) -> error("Shit, cannot find function in fdefset:" ++ ident ++ ":" ++ show fdefset)

getExpType state (E.Dot expr ident) = 
  let
    (texpr, exprType) = getExpType state expr
    fieldType = getStructFieldType state exprType ident
  in
    (T.Dot texpr ident fieldType, fieldType)
getExpType state (E.PointerStar expr) = 
  let
    (texpr, exprType) = getExpType state expr
    derefType = dereferenceType exprType
  in
    (T.PointerStar texpr derefType, derefType)
getExpType state (E.ArrayAccess expr1 expr2) = 
  let
    (texpr1, expr1Type) = getExpType state expr1
    (texpr2, expr2Type) = getExpType state expr2
    elemType = getArrayElementType expr1Type
  in
    case expr2Type of
      T.CInt -> (T.ArrayAccess texpr1 texpr2 elemType, elemType)
      _ -> error("Array index is not an integer:" ++ show expr2)
getExpType state (E.NULL) = (T.NULL (T.CPtr T.CAny), (T.CPtr T.CAny))
getExpType state (E.Alloc ctype) =
  let
    ttype = eastTypeToTastType ctype
    pointerType = T.CPtr ttype
    -- tastPointerType = case ttype of
    --   -- For codegen, alloc(struct) should be a struct
    --   T.CStruct _ -> ttype
    --   _ -> T.CPtr ttype
    knowTheSize = doWeKnowTheSizeOfThisType state ttype
  in
    case (knowTheSize, isTypeVoidDerivative ttype) of
      (_, True) -> error("can't alloc void")
      (True ,_)-> (T.Alloc ttype pointerType, pointerType)
      (False,_) -> error ("I don't know the size of this struct, so I can't alloc:" ++ show ttype)

getExpType state (E.AllocArray ctype expr) =
  let
    (texpr, exprType) = getExpType state expr
    ttype = eastTypeToTastType ctype
    arrayType = T.CArray ttype
  in
    case (exprType, isTypeVoidDerivative ttype) of
      (_, True) -> error("Don't use void in allocarray")
      (T.CInt, _) -> (T.AllocArray ttype texpr arrayType, arrayType)
      (_     , _) -> error("Second argument of AllocArray is not an integer!" ++ show expr)

-- CAny and CInt should combine and form CInt
combineTypes :: T.CType -> T.CType -> T.CType
combineTypes expr1Type expr2Type = 
  case (expr1Type, expr2Type) of
    (CPtr t1, CPtr t2) -> CPtr (combineTypes t1 t2)
    (CArray t1, CArray t2) -> CArray (combineTypes t1 t2)
    (CAny, t2) -> t2
    (t1, CAny) -> t1
    (t1, t2) -> (case (t1 == t2) of
      True -> t1
      False -> error ("Cannot combine unequal types:" ++ show expr1Type ++ " and " ++ show expr2Type)
      )

-- If I don't know the size of the type, then I can't alloc
-- If struct not defined yet, I can't alloc!!!
doWeKnowTheSizeOfThisType :: TypeState -> T.CType -> Bool
doWeKnowTheSizeOfThisType state ttype =
  let
    structmap = getStructMap state
  in
    case ttype of
      CStruct ident -> Map.member ident structmap
      _ -> True


checkCall :: TypeState -> [T.CType] -> T.Ident -> T.CType
checkCall state argtypes ident =
  let
    funcmap = getFuncMap state
    typemap = getTypeMap state
    (expectedOutput, rawInput) = case Map.member ident funcmap of
      True -> funcmap Map.! ident
      False -> error ("checkCall: Function not found:" ++ show ident ++ " in map:" ++ show funcmap)
    expectedInput = map fst rawInput
    isShadowed = Map.member ident typemap
    isArgTypesEqual = areTypesEqualExprList expectedInput argtypes
  in
    case (isShadowed, ident, isArgTypesEqual) of
      -- Shadowing of abort is allowed
      (True, "abort", True) -> expectedOutput
      (True, _ , _) -> error("Function name has been shadowed by a local variable." ++ ident)
      (False, _, True) -> expectedOutput
      (_, _, False) -> error("Function arg types do not agree: " ++ ident)

areTypesEqualExprList arglist1 arglist2 =
  (length arglist1 == length arglist2) && (all (\(type1, type2) -> areTypesEqualExpr type1 type2) (zip arglist1 arglist2))

-- Gets the type of the identifier
getIdentType :: TypeState -> T.Ident -> T.CType
getIdentType state ident = 
  let
    typemap = getTypeMap state
  in
    case (Map.member ident typemap) of
      True -> (Map.!) typemap ident
      False -> error("getIdentType: Cannot find identifier in map:" ++ show ident)

isTypeLarge :: T.CType -> Bool
isTypeLarge (T.CStruct _) = True
isTypeLarge _ = False

areTypesEqualExpr :: T.CType -> T.CType -> Bool
-- According to Lab 3, voids cannot appear in expressions.
areTypesEqualExpr T.CVoid _ = error("Cannot compare equality for void type")
areTypesEqualExpr _ T.CVoid = error("Cannot compare equality for void type")
areTypesEqualExpr t1 t2 =
  case (isTypeVoidDerivative t1, isTypeVoidDerivative t2) of
    (False, False) -> areTypesEqual t1 t2
    _ -> error("Types cannot be void or pointers involving voids in expressions")

isTypeVoidDerivative :: T.CType -> Bool
isTypeVoidDerivative T.CVoid = True
isTypeVoidDerivative (T.CPtr ctype) = isTypeVoidDerivative ctype
isTypeVoidDerivative (T.CArray ctype) = isTypeVoidDerivative ctype
isTypeVoidDerivative _ = False

areTypesEqual :: T.CType -> T.CType -> Bool
-- According to Lecture on Mutable Stores, we can compare and assign NULL with any pointer
areTypesEqual (T.CPtr t1) (T.CPtr t2) = areTypesEqual t1 t2
areTypesEqual (T.CArray t1) (T.CArray t2) = areTypesEqual t1 t2
areTypesEqual T.CAny _ = True
areTypesEqual _ T.CAny = True
areTypesEqual ctype1 ctype2 = (ctype1 == ctype2)

dereferenceType :: T.CType -> T.CType
dereferenceType (T.CPtr CAny) = error ("Cannot dereference NULL.")
dereferenceType (T.CPtr ctype) = ctype
dereferenceType ctype = error("Attempting to dereference non-pointer" ++ show ctype)


getArrayElementType :: T.CType -> T.CType
getArrayElementType (T.CArray ctype) = ctype
getArrayElementType ctype = error("Type is not an array!: " ++ show ctype)

getStructFieldType :: TypeState -> T.CType -> T.Ident -> T.CType
getStructFieldType state (T.CStruct structname) fieldname =
  let
    structmap = getStructMap state
    structfieldmap = 
      case Map.member structname structmap of
        True -> structmap Map.! structname
        False -> error("struct not found")
    fieldType = 
      case Map.member fieldname structfieldmap of
        True -> structfieldmap Map.! fieldname
        False -> error("field not found")
  in
    fieldType

getUnaryOpType :: Unop -> T.CType
getUnaryOpType Neg =  T.CInt
getUnaryOpType Flip = T.CInt
getUnaryOpType Not =  T.CBool

getBinopType :: Binop -> BinopType
getBinopType Add = IntegerBinop
getBinopType Sub = IntegerBinop
getBinopType Mul = IntegerBinop
getBinopType Div = IntegerBinop
getBinopType Mod = IntegerBinop
getBinopType ShiftL = IntegerBinop
getBinopType ShiftR = IntegerBinop
getBinopType Less = RelativeEqual
getBinopType Leq = RelativeEqual
getBinopType Geq = RelativeEqual
getBinopType Greater = RelativeEqual
getBinopType Eq = PolyEqual
getBinopType Neq = PolyEqual
getBinopType BAnd = IntegerBinop
getBinopType BXor = IntegerBinop
getBinopType BOr = IntegerBinop
getBinopType LAnd = LogicalBinop
getBinopType LOr = LogicalBinop


eastTypeToTastType :: E.CType -> T.CType
eastTypeToTastType E.CInt =    T.CInt
eastTypeToTastType E.CBool =   T.CBool
eastTypeToTastType E.CNoType = T.CNoType
eastTypeToTastType E.CVoid =   T.CVoid
eastTypeToTastType (E.CPtr ctype   ) = T.CPtr (eastTypeToTastType ctype)
eastTypeToTastType (E.CArray ctype ) = T.CArray (eastTypeToTastType ctype)
eastTypeToTastType (E.CStruct ident) = T.CStruct ident
eastTypeToTastType (E.CAny    ) = T.CAny    

paramListToTParamList :: [E.Param] -> [T.Param]
paramListToTParamList paramlist = map (\(E.Param ctype ident) -> T.Param (eastTypeToTastType ctype) ident) paramlist