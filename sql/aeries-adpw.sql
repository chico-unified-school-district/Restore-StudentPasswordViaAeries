SELECT STU.ID,SUP.SC,SUP.SN,SUP.ADPW,STU.BD
FROM SUP LEFT JOIN STU ON STU.SC = SUP.SC AND STU.SN = SUP.SN
WHERE SUP.ADPW = 'Y'