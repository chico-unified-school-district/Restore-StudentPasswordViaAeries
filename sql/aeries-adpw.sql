SELECT STU.ID,SUP.SC,SUP.SN,SUP.ADPW,STU.GR
,format(cast(STU.BD as date),'yyMMdd') AS BD
FROM SUP LEFT JOIN STU ON STU.SC = SUP.SC AND STU.SN = SUP.SN
WHERE SUP.ADPW = 'Y'
--AND STU.SC IN ({0})