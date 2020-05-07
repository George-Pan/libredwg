// TODO DEBUGGING
#define DWG_TYPE DWG_TYPE_BLOCKVISIBILITYGRIP
#include "common.c"

void
api_process (dwg_object *obj)
{
  int error, isnew;
  BITCODE_BL ee_bl1;
  BITCODE_BL ee_bl2;
  BITCODE_BL ee_bl3;
  BITCODE_BL ee_bs1;
  BITCODE_BS ee_type;
  BITCODE_BL ee_bl4;
  BITCODE_T be_t;
  BITCODE_BL be_bl1;
  BITCODE_BL be_bl2;
  BITCODE_BL be_bl3;
  BITCODE_BL bg_bl1;
  BITCODE_BL bg_bl2;
  BITCODE_3BD bg_pt;
  BITCODE_B bg_insert_cycling;
  BITCODE_BL bg_insert_cycling_weight;

  Dwg_Version_Type dwg_version = obj->parent->header.version;
#ifdef DEBUG_CLASSES
  dwg_obj_blockvisibilitygrip *_obj = dwg_object_to_BLOCKVISIBILITYGRIP (obj);

  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, ee_bl1, BL, ee_bl1);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, ee_bl2, BL, ee_bl2);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, ee_bl3, BL, ee_bl3);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, ee_bs1, BL, ee_bs1);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, ee_type, BS, ee_type);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, ee_bl4, BL, ee_bl4);
  CHK_ENTITY_UTF8TEXT (_obj, BLOCKVISIBILITYGRIP, be_t, be_t);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, be_bl1, BL, be_bl1);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, be_bl2, BL, be_bl2);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, be_bl3, BL, be_bl3);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, bg_bl1, BL, bg_bl1);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, bg_bl2, BL, bg_bl2);
  CHK_ENTITY_3RD (_obj, BLOCKVISIBILITYGRIP, bg_pt, bg_pt);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, bg_insert_cycling, B, bg_insert_cycling);
  CHK_ENTITY_TYPE (_obj, BLOCKVISIBILITYGRIP, bg_insert_cycling_weight, BL, bg_insert_cycling_weight);
#endif
}
