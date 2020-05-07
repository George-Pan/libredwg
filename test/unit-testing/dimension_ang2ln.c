#define DWG_TYPE DWG_TYPE_DIMENSION_ANG2LN
#include "common.c"

void
api_process (dwg_object *obj)
{
  int error;
  double elevation, act_measurement, horiz_dir, lspace_factor, text_rotation,
      ins_rotation;
  BITCODE_B flip_arrow1, flip_arrow2;
  BITCODE_RC class_version, flag, flag1;
  BITCODE_BS lspace_style, attachment;
  char *user_text;
  dwg_point_2d text_midpt, pt12, pt2d;
  dwg_point_3d def_pt, ext, ins_scale, pt3d;
  BITCODE_H dimstyle, block;
  int isnew;

  BITCODE_2BD arc_def_pt;
  BITCODE_3BD xline1start_pt;
  BITCODE_3BD xline1end_pt;
  BITCODE_3BD xline2start_pt;
  BITCODE_3BD xline2end_pt;
  
  dwg_ent_dim_ang2ln *dim_ang2ln = dwg_object_to_DIMENSION_ANG2LN (obj);
  dwg_ent_dim *dim = dwg_object_to_DIMENSION (obj);

  /* common */
  CHK_ENTITY_TYPE (dim, DIMENSION_ANG2LN, class_version, RC, class_version);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, lspace_style, BS,
                         lspace_style);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, lspace_factor, BD,
                         lspace_factor);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, act_measurement, BD,
                         act_measurement);
  CHK_ENTITY_TYPE (dim, DIMENSION_ANG2LN, attachment, BS, attachment);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, elevation, BD, elevation);
  CHK_ENTITY_3RD (dim, DIMENSION_ANG2LN, extrusion, ext);
  CHK_ENTITY_2RD_W_OLD (dim, DIMENSION_ANG2LN, clone_ins_pt, pt12);
  CHK_ENTITY_2RD_W_OLD (dim, DIMENSION_ANG2LN, text_midpt, text_midpt);
  CHK_ENTITY_UTF8TEXT (dim, DIMENSION_ANG2LN, user_text, user_text);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, text_rotation, BD,
                         text_rotation);
  CHK_ENTITY_3RD_W_OLD (dim, DIMENSION_ANG2LN, ins_scale, ins_scale);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, ins_rotation, BD,
                         ins_rotation);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, horiz_dir, BD, horiz_dir);
  CHK_ENTITY_MAX (dim, DIMENSION_ANG2LN, text_rotation, BD, MAX_ANGLE);
  CHK_ENTITY_MAX (dim, DIMENSION_ANG2LN, ins_rotation, BD, MAX_ANGLE);
  CHK_ENTITY_MAX (dim, DIMENSION_ANG2LN, horiz_dir, BD, MAX_ANGLE);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, flip_arrow1, B, flip_arrow1);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, flip_arrow2, B, flip_arrow2);
  CHK_ENTITY_TYPE_W_OLD (dim, DIMENSION_ANG2LN, flag1, RC, flag1);
  CHK_ENTITY_TYPE (dim, DIMENSION_ANG2LN, flag, RC, flag);
  CHK_ENTITY_3RD_W_OLD (dim_ang2ln, DIMENSION_ANG2LN, def_pt, def_pt);

  /* ang2ln */
  CHK_ENTITY_2RD (dim_ang2ln, DIMENSION_ANG2LN, arc_def_pt, arc_def_pt);
  CHK_ENTITY_3RD (dim_ang2ln, DIMENSION_ANG2LN, xline1start_pt, xline1start_pt);
  dwg_ent_dim_ang2ln_get_13_pt (dim_ang2ln, &pt3d, &error);
  if (error || memcmp (&xline1start_pt, &pt3d, sizeof (xline1start_pt)))
    fail ("old API dwg_ent_dim_ang2ln_get_13_pt");
  else
    pass ();
  CHK_ENTITY_3RD (dim_ang2ln, DIMENSION_ANG2LN, xline1end_pt, xline1end_pt);
  dwg_ent_dim_ang2ln_get_14_pt (dim_ang2ln, &pt3d, &error);
  if (error || memcmp (&xline1end_pt, &pt3d, sizeof (xline1end_pt)))
    fail ("old API dwg_ent_dim_ang2ln_get_14_pt");
  else
    pass ();
  CHK_ENTITY_3RD (dim_ang2ln, DIMENSION_ANG2LN, xline2start_pt, xline2start_pt);
  /*
  dwg_ent_dim_ang2ln_get_15_pt (dim_ang2ln, &pt3d, &error);
  if (error || memcmp (&xline2start_pt, &pt3d, sizeof (xline2start_pt)))
    fail ("old API dwg_ent_dim_ang2ln_get_15_pt");
  else
    pass ();
  */
  CHK_ENTITY_3RD (dim_ang2ln, DIMENSION_ANG2LN, xline2end_pt, xline2end_pt);
  dwg_ent_dim_ang2ln_get_16_pt (dim_ang2ln, &pt3d, &error);
  if (error || memcmp (&xline2end_pt, &pt3d, sizeof (xline2end_pt)))
    fail ("old API dwg_ent_dim_ang2ln_get_16_pt");
  else
    pass ();

  CHK_ENTITY_H (dim_ang2ln, DIMENSION_ANG2LN, dimstyle, dimstyle);
  CHK_ENTITY_H (dim_ang2ln, DIMENSION_ANG2LN, block, block);
}
