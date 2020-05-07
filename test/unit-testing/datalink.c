// TODO DEBUGGING
#define DWG_TYPE DWG_TYPE_DATALINK
#include "common.c"

void
api_process (dwg_object *obj)
{
  int error, isnew;
  BITCODE_BS class_version; /*<! DXF 70 1/10 */
  BITCODE_T data_adapter;/*<! DXF 1  */
  BITCODE_T description;/*<! DXF 300  */
  BITCODE_T tooltip;	/*<! DXF 301  */
  BITCODE_T connection_string;	/*<! DXF 302  */
  BITCODE_BL option;	/*<! DXF 90  2 */
  BITCODE_BL update_option;/*<! DXF 91  1179649 */
  BITCODE_BL bl92;	/*<! DXF 92  1 */
  BITCODE_BS year;	/*<! DXF 170  */
  BITCODE_BS month;	/*<! DXF 171  */
  BITCODE_BS day;	/*<! DXF 172  */
  BITCODE_BS hour;	/*<! DXF 173  */
  BITCODE_BS minute;	/*<! DXF 174  */
  BITCODE_BS seconds;	/*<! DXF 175  */
  BITCODE_BS msec;	/*<! DXF 176  */
  BITCODE_BS path_option; /*<! DXF 177  1 */
  BITCODE_BL bl93;	  /*<! DXF 93   0 */
  BITCODE_T update_status;/*<! DXF 304  */
  BITCODE_BL i, num_customdata; // 94
  Dwg_DATALINK_customdata *customdata; // 330 + 304
  BITCODE_H hardowner;	/*<! DXF 360  */

  Dwg_Version_Type dwg_version = obj->parent->header.version;
#ifdef DEBUG_CLASSES
  dwg_obj_datalink *_obj = dwg_object_to_DATALINK (obj);

  CHK_ENTITY_TYPE (_obj, DATALINK, class_version, BS, class_version);
  CHK_ENTITY_UTF8TEXT (_obj, DATALINK, data_adapter, data_adapter);
  CHK_ENTITY_UTF8TEXT (_obj, DATALINK, description, description);
  CHK_ENTITY_UTF8TEXT (_obj, DATALINK, tooltip, tooltip);
  CHK_ENTITY_UTF8TEXT (_obj, DATALINK, connection_string, connection_string);

  CHK_ENTITY_TYPE (_obj, DATALINK, option, BL, option);
  CHK_ENTITY_TYPE (_obj, DATALINK, update_option, BL, update_option);
  CHK_ENTITY_TYPE (_obj, DATALINK, bl92, BL, bl92);
  CHK_ENTITY_TYPE (_obj, DATALINK, year, BS, year);
  CHK_ENTITY_TYPE (_obj, DATALINK, month, BS, month);
  CHK_ENTITY_TYPE (_obj, DATALINK, day, BS, day);
  CHK_ENTITY_TYPE (_obj, DATALINK, hour, BS, hour);
  CHK_ENTITY_TYPE (_obj, DATALINK, minute, BS, minute);
  CHK_ENTITY_TYPE (_obj, DATALINK, seconds, BS, seconds);
  CHK_ENTITY_TYPE (_obj, DATALINK, msec, BS, msec);
  CHK_ENTITY_TYPE (_obj, DATALINK, path_option, BS, path_option);
  CHK_ENTITY_TYPE (_obj, DATALINK, bl93, BL, bl93);
  CHK_ENTITY_UTF8TEXT (_obj, DATALINK, update_status, update_status);
  CHK_ENTITY_TYPE (_obj, DATALINK, num_customdata, BL, num_customdata);
  if (!dwg_dynapi_entity_value (_obj, "DATALINK", "customdata", &customdata, NULL))
    fail ("DATALINK.customdata");
  if (num_customdata)
    {
      if (!customdata)
        fail ("DATALINK.customdata");
      else
        for (i = 0; i < num_customdata; i++)
          {
            CHK_SUBCLASS_H (customdata[i], DATALINK_customdata, target);
            CHK_SUBCLASS_UTF8TEXT (customdata[i], DATALINK_customdata, text);
          }
    }
  CHK_ENTITY_H (_obj, DATALINK, hardowner, hardowner);

#endif
}
