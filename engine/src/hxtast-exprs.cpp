/* hxtast-exprs.cpp — hxt_serialize / hxt_deserialize_body for MCExpression
 *                    subclasses (Task 30).
 *
 * Covered here:
 *   MCLiteral, MCVarref, MCIs, MCThere
 *   MCBinaryOperator, MCMultiBinaryOperator, MCUnaryOperator (virtual dispatch)
 *   MCMinus (special — handles both binary and unary negation)
 *   MCAnd, MCOr, MCConcat (direct MCExpression subclasses)
 *   MCProperty (stub — complex UI expression)
 *   MCChunk (full — handles the named MCCRef slot chain)
 *
 * MCFuncref hxt_serialize/hxt_deserialize_body are in hxtast-stmts.cpp
 * because MCHandref is declared in keywords.h.
 *
 * Note: the engine is compiled with -fno-rtti.  dynamic_cast is therefore
 * unavailable.  Operator type dispatch uses the virtual hxt_expr_type()
 * method added to each concrete operator class in operator.h.  Casts in
 * deserialize paths use static_cast because the type byte we just read
 * guarantees the correct runtime type.
 *
 * Copyright (C) HyperXTalk contributors.  See COPYING for licence details.
 */

#include "prefix.h"

#include "hxtast.h"
#include "express.h"
#include "literal.h"
#include "variable.h"   // MCVarref
#include "operator.h"   // MCBinaryOperator, MCIs, MCThere, MCAnd, MCOr, …
#include "chunk.h"      // MCChunk, MCCRef
#include "property.h"   // MCProperty
#include "parsedef.h"

// Free function declared in hxtast-base.cpp.
extern bool hxt_serialize_expr(MCHXTASTWriter &w, const MCExpression *expr);

// (No RTTI dispatch function needed — each concrete operator class overrides
//  hxt_expr_type() in operator.h, so the base-class hxt_serialize() methods
//  below call this->hxt_expr_type() via the vtable.)

// ============================================================
//  MCLiteral
// ============================================================

bool MCLiteral::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_Literal, line, pos);
    w.put_u32(w.intern_const_valueref(value));
    return true;
}

bool MCLiteral::hxt_deserialize_body(MCHXTASTReader &r)
{
    MCValueRef v = nullptr;
    if (!r.get_const_field(v))
        return false;
    MCValueRelease(value);
    value = v;   // already retained by get_const_field
    return true;
}

// ============================================================
//  MCVarref
//
// Serialization writes the scope + index so the factory in hxtast-base.cpp
// can reconstruct with the right MCVarref constructor.
// Dimension index expressions (array access) are also written.
// ============================================================

bool MCVarref::hxt_serialize(MCHXTASTWriter &w) const
{
    uint8_t scope;
    if (isparam)
        scope = kHXTVarScope_Param;
    else if (isscriptlocal)
        scope = kHXTVarScope_ScriptLocal;
    else
        scope = kHXTVarScope_Local;

    w.begin_expr(kHXTExpr_Varref, line, pos);
    w.put_u8(scope);
    w.put_u16(index);
    w.put_u8(dimensions);

    if (dimensions == 0)
    {
        // nothing
    }
    else if (dimensions == 1)
    {
        hxt_serialize_expr(w, exp);
    }
    else
    {
        for (uint8_t i = 0; i < dimensions; ++i)
            hxt_serialize_expr(w, exps[i]);
    }
    return true;
}

// ============================================================
//  MCIs  (form + valid + delimiter, then left + right)
// ============================================================

bool MCIs::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_Is, line, pos);
    w.put_u8(uint8_t(form));
    w.put_u8(uint8_t(valid));
    w.put_u8(uint8_t(delimiter));
    hxt_serialize_expr(w, left);
    hxt_serialize_expr(w, right);
    return true;
}

bool MCIs::hxt_deserialize_body(MCHXTASTReader &r)
{
    uint8_t form_b = 0, valid_b = 0, delim_b = 0;
    if (!r.get_u8(form_b) || !r.get_u8(valid_b) || !r.get_u8(delim_b))
        return false;
    form      = Is_type(form_b);
    valid     = Is_validation(valid_b);
    delimiter = Chunk_term(delim_b);
    left  = MCExpression::hxt_deserialize(r); if (!r.ok()) return false;
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

// ============================================================
//  MCThere  (form + mode + chunk-expression for the object)
// ============================================================

bool MCThere::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_There, line, pos);
    w.put_u8(uint8_t(form));
    w.put_u8(uint8_t(mode));
    // object is an MCChunk — serialize it as an expression (may be null).
    hxt_serialize_expr(w, object);
    return true;
}

bool MCThere::hxt_deserialize_body(MCHXTASTReader &r)
{
    uint8_t form_b = 0, mode_b = 0;
    if (!r.get_u8(form_b) || !r.get_u8(mode_b))
        return false;
    form = Is_type(form_b);
    mode = There_mode(mode_b);
    MCExpression *obj_expr = MCExpression::hxt_deserialize(r);
    if (!r.ok()) return false;
    // The serializer always writes an MCChunk (or null) here; static_cast is safe.
    object = static_cast<MCChunk *>(obj_expr);
    return true;
}

// ============================================================
//  MCBinaryOperator — base for all binary op templates
//  (MCPow, MCEqual, MCNotEqual, MCLessThan, MCGreaterThan,
//   MCLessThanEqual, MCGreaterThanEqual, MCContains, MCConcatSpace)
// ============================================================

bool MCBinaryOperator::hxt_serialize(MCHXTASTWriter &w) const
{
    HXTExprType t = hxt_expr_type();
    if (t == kHXTExpr_Null)
        return true;  // unknown subclass — write nothing
    w.begin_expr(t, line, pos);
    hxt_serialize_expr(w, left);
    hxt_serialize_expr(w, right);
    return true;
}

bool MCBinaryOperator::hxt_deserialize_body(MCHXTASTReader &r)
{
    left  = MCExpression::hxt_deserialize(r); if (!r.ok()) return false;
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

// ============================================================
//  MCMultiBinaryOperator — base for MCPlus, MCTimes, MCOver,
//  MCMod, MCDiv.  MCMinus overrides with its own version.
// ============================================================

bool MCMultiBinaryOperator::hxt_serialize(MCHXTASTWriter &w) const
{
    HXTExprType t = hxt_expr_type();
    if (t == kHXTExpr_Null)
        return true;
    w.begin_expr(t, line, pos);
    hxt_serialize_expr(w, left);
    hxt_serialize_expr(w, right);
    return true;
}

bool MCMultiBinaryOperator::hxt_deserialize_body(MCHXTASTReader &r)
{
    left  = MCExpression::hxt_deserialize(r); if (!r.ok()) return false;
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

// ── MCMinus (binary subtraction and unary negation) ───────────────────────

bool MCMinus::hxt_serialize(MCHXTASTWriter &w) const
{
    if (left == nullptr)
    {
        // Unary form: -expr
        w.begin_expr(kHXTExpr_Negate, line, pos);
        hxt_serialize_expr(w, right);
    }
    else
    {
        // Binary form: left - right
        w.begin_expr(kHXTExpr_Sub, line, pos);
        hxt_serialize_expr(w, left);
        hxt_serialize_expr(w, right);
    }
    return true;
}

// ============================================================
//  MCUnaryOperator — MCNot
// ============================================================

bool MCUnaryOperator::hxt_serialize(MCHXTASTWriter &w) const
{
    HXTExprType t = hxt_expr_type();
    if (t == kHXTExpr_Null)
        t = kHXTExpr_Not;   // safe default for MCNot (shouldn't be needed)
    w.begin_expr(t, line, pos);
    hxt_serialize_expr(w, right);
    return true;
}

bool MCUnaryOperator::hxt_deserialize_body(MCHXTASTReader &r)
{
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

// ============================================================
//  MCAnd, MCOr  (direct MCExpression subclasses with left/right)
// ============================================================

bool MCAnd::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_And, line, pos);
    hxt_serialize_expr(w, left);
    hxt_serialize_expr(w, right);
    return true;
}
bool MCAnd::hxt_deserialize_body(MCHXTASTReader &r)
{
    left  = MCExpression::hxt_deserialize(r); if (!r.ok()) return false;
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

bool MCOr::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_Or, line, pos);
    hxt_serialize_expr(w, left);
    hxt_serialize_expr(w, right);
    return true;
}
bool MCOr::hxt_deserialize_body(MCHXTASTReader &r)
{
    left  = MCExpression::hxt_deserialize(r); if (!r.ok()) return false;
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

// ============================================================
//  MCConcat  (direct MCExpression subclass with left/right)
// ============================================================

bool MCConcat::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_Concat, line, pos);
    hxt_serialize_expr(w, left);
    hxt_serialize_expr(w, right);
    return true;
}
bool MCConcat::hxt_deserialize_body(MCHXTASTReader &r)
{
    left  = MCExpression::hxt_deserialize(r); if (!r.ok()) return false;
    right = MCExpression::hxt_deserialize(r);
    return r.ok();
}

// ============================================================
//  MCChunk
//
//  The chunk expression has up to 18 named MCCRef* slots.
//  We serialize only non-null slots as (slot_id, etype, otype, ptype,
//  startpos, endpos) chains.
//
//  Binary layout:
//    uint8_t   dest_type       (Dest_type enum)
//    <expr>    source          (base expression; may be kHXTExpr_Null)
//    uint8_t   has_destvar     (1 = simple variable, else 0)
//    [<expr>]  destvar         (MCVarref expr if has_destvar)
//    uint8_t   slot_count      (number of non-null cref slots to follow)
//    slot[slot_count]:
//      uint8_t  slot_id        (which named slot, 0..17)
//      uint8_t  chain_len      (MCCRef nodes in this slot's chain)
//      cref[chain_len]:
//        uint8_t  etype
//        uint8_t  otype
//        uint8_t  ptype
//        <expr>   startpos
//        <expr>   endpos
// ============================================================

// Named MCCRef* slots in declaration order.
struct ChunkSlot { const MCCRef *ptr; uint8_t id; };

bool MCChunk::hxt_serialize(MCHXTASTWriter &w) const
{
    // We are a member function — can access all private fields.
    w.begin_expr(kHXTExpr_Chunk, line, pos);
    w.put_u8(uint8_t(desttype));

    // Source expression (the base container / variable).
    hxt_serialize_expr(w, source);

    // destvar: simple variable destination (optimization used by many stmts).
    if (destvar != nullptr)
    {
        w.put_u8(1);
        hxt_serialize_expr(w, destvar);
    }
    else
    {
        w.put_u8(0);
    }

    // Collect all non-null named slots.
    const MCCRef *slots[] = {
        url, stack, background, card, group, object, element,
        cline, token, item, word, character,
        codepoint, codeunit, byte, paragraph, sentence, trueword
    };
    static const uint8_t kSlotCount = 18;

    // Count non-null slots first.
    uint8_t non_null = 0;
    for (uint8_t i = 0; i < kSlotCount; ++i)
        if (slots[i] != nullptr) ++non_null;
    w.put_u8(non_null);

    for (uint8_t i = 0; i < kSlotCount; ++i)
    {
        const MCCRef *cref = slots[i];
        if (cref == nullptr) continue;

        // Count chain length.
        uint8_t chain_len = 0;
        for (const MCCRef *c = cref; c != nullptr; c = c->next)
            ++chain_len;

        w.put_u8(i);            // slot_id
        w.put_u8(chain_len);
        for (const MCCRef *c = cref; c != nullptr; c = c->next)
        {
            w.put_u8(uint8_t(c->etype));
            w.put_u8(uint8_t(c->otype));
            w.put_u8(uint8_t(c->ptype));
            hxt_serialize_expr(w, c->startpos);
            hxt_serialize_expr(w, c->endpos);
        }
    }
    return true;
}

bool MCChunk::hxt_deserialize_body(MCHXTASTReader &r)
{
    uint8_t dest_type_b = 0;
    if (!r.get_u8(dest_type_b)) return false;
    desttype = Dest_type(dest_type_b);

    // source expression
    source = MCExpression::hxt_deserialize(r);
    if (!r.ok()) return false;

    // destvar
    uint8_t has_dv = 0;
    if (!r.get_u8(has_dv)) return false;
    if (has_dv)
    {
        MCExpression *dv_expr = MCExpression::hxt_deserialize(r);
        if (!r.ok()) return false;
        // The serializer always writes an MCVarref here; static_cast is safe.
        destvar = static_cast<MCVarref *>(dv_expr);
    }

    // Slot chains
    uint8_t slot_count = 0;
    if (!r.get_u8(slot_count)) return false;

    // Pointers to the named MCCRef* members in declaration order.
    MCCRef **slot_ptrs[] = {
        &url, &stack, &background, &card, &group, &object, &element,
        &cline, &token, &item, &word, &character,
        &codepoint, &codeunit, &byte, &paragraph, &sentence, &trueword
    };

    for (uint8_t s = 0; s < slot_count; ++s)
    {
        uint8_t slot_id = 0, chain_len = 0;
        if (!r.get_u8(slot_id) || !r.get_u8(chain_len)) return false;
        if (slot_id >= 18) return false;

        MCCRef *head = nullptr;
        MCCRef *tail = nullptr;
        for (uint8_t ci = 0; ci < chain_len; ++ci)
        {
            uint8_t et = 0, ot = 0, pt = 0;
            if (!r.get_u8(et) || !r.get_u8(ot) || !r.get_u8(pt)) return false;
            MCCRef *cref = new MCCRef;
            cref->etype    = Chunk_term(et);
            cref->otype    = Chunk_term(ot);
            cref->ptype    = Chunk_term(pt);
            cref->startpos = MCExpression::hxt_deserialize(r);
            if (!r.ok()) { delete cref; if (head) delete head; return false; }
            cref->endpos   = MCExpression::hxt_deserialize(r);
            if (!r.ok()) { delete cref; if (head) delete head; return false; }
            cref->next     = nullptr;
            if (!head) head = cref;
            else       tail->next = cref;
            tail = cref;
        }
        *slot_ptrs[slot_id] = head;
    }
    return r.ok();
}

// ============================================================
//  MCProperty  (stub — complex UI expression)
//
//  MCProperty serialization is complex (requires Properties enum lookup,
//  effective flag, custom property name, target chunk).
//  A minimal implementation is provided; the full version can be added
//  when property serialization becomes important for .hxtlib code.
// ============================================================

bool MCProperty::hxt_serialize(MCHXTASTWriter &w) const
{
    w.begin_expr(kHXTExpr_Property, line, pos);
    // Write the property id, effective flag, and target chunk.
    w.put_u16(uint16_t(which));
    w.put_u8(effective ? 1u : 0u);
    // customprop name (may be nil)
    uint32_t cpname_idx = customprop.IsSet()
                          ? w.intern_nameref(*customprop)
                          : 0u;
    w.put_u32(cpname_idx);
    // customindex expression
    hxt_serialize_expr(w, customindex.Get());
    // target chunk
    hxt_serialize_expr(w, target.Get());
    return true;
}

bool MCProperty::hxt_deserialize_body(MCHXTASTReader &r)
{
    uint16_t which_v = 0;
    uint8_t  eff_v   = 0;
    if (!r.get_u16(which_v) || !r.get_u8(eff_v)) return false;
    which     = Properties(which_v);
    effective = eff_v ? True : False;

    // customprop name
    MCNameRef cpn = nullptr;
    if (!r.get_nameref_field(cpn)) return false;
    customprop = cpn;   // MCNewAutoNameRef takes ownership
    MCValueRelease(cpn);

    // customindex
    MCExpression *ci = MCExpression::hxt_deserialize(r);
    if (!r.ok()) return false;
    customindex.Reset(ci);

    // target chunk
    MCExpression *tgt = MCExpression::hxt_deserialize(r);
    if (!r.ok()) return false;
    // The serializer always writes an MCChunk (or null) for target; static_cast is safe.
    target.Reset(static_cast<MCChunk *>(tgt));

    return r.ok();
}
